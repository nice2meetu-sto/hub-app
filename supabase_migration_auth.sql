-- ============================================================
--  마이그레이션: 인증 로직 (ROADMAP 2-1 본구현 + 2-3 관리자 이전 + 2-5 계정 연결)
--  supabase_migration_multihub.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  내용
--    · PIN 잠금 본구현: login이 실패 횟수를 기록(5회 → 10분 잠금).
--      예외를 던지면 카운터 증가가 롤백되므로 login은 예외 대신
--      {ok:false, error:...} 반환 방식으로 전환 (app.js도 함께 수정됨)
--    · create_hub: 로그인(Auth)한 사용자가 허브 개설 → owner 지정,
--      초대코드 발급, 기본 분류 시딩
--    · 허브 관리(owner/공동 admin 전용): 이름 변경, 초대코드 확인/재발급,
--      관리자(owner) 이전, 공동 admin 추가/제거
--    · link_player: Auth 계정을 허브 멤버에 연결(PIN = 본인 증명).
--      owner가 자기 멤버에 연결하면 그 멤버는 role=admin 승격
-- ============================================================

-- ============================================================
--  1) PIN 잠금 본구현 — login 반환값 방식 전환
--     실패: {ok:false, error} 반환(트랜잭션 커밋 → 카운터 유지)
--     5회 연속 실패 → 10분 잠금. 성공 시 카운터 리셋.
-- ============================================================
drop function if exists public.login(text, text, text);
create or replace function public.login(p_name text, p_pin text, p_hub_id text default 'H001')
returns json
language plpgsql security definer   -- volatile: 실패 카운터를 기록해야 함
set search_path = public, extensions
as $$
declare r public.players; v_fail int;
begin
  if coalesce(p_name,'') = '' or coalesce(p_pin,'') = '' then
    return json_build_object('ok', false, 'error', '이름과 PIN을 입력하세요.'); end if;

  select * into r from public.players
   where hub_id = p_hub_id and lower(btrim(name)) = lower(btrim(p_name));
  if not found then
    return json_build_object('ok', false, 'error', '사용자를 찾을 수 없습니다.'); end if;
  if coalesce(r.status, 'active') = 'left' then
    return json_build_object('ok', false, 'error', '탈퇴한 회원입니다.'); end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then
    return json_build_object('ok', false, 'error',
      '시도 5회 초과로 잠시 잠겼습니다. ' ||
      ceil(extract(epoch from (r.pin_locked_until - now())) / 60)::int || '분 후 다시 시도하세요.');
  end if;

  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then
    v_fail := coalesce(r.pin_failed, 0) + 1;
    update public.players
       set pin_failed = v_fail,
           pin_locked_until = case when v_fail >= 5 then now() + interval '10 minutes' else null end
     where player_id = r.player_id;
    return json_build_object('ok', false, 'error',
      case when v_fail >= 5 then '시도 5회 초과로 10분간 잠겼습니다.'
           else 'PIN이 올바르지 않습니다. (' || v_fail || '/5)'
      end);
  end if;

  -- 성공: 카운터 리셋
  if coalesce(r.pin_failed, 0) > 0 or r.pin_locked_until is not null then
    update public.players set pin_failed = 0, pin_locked_until = null
     where player_id = r.player_id;
  end if;
  return json_build_object('ok', true, 'player_id', r.player_id, 'name', r.name,
                           'role', coalesce(r.role,'member'), 'hub_id', r.hub_id);
end $$;
grant execute on function public.login(text, text, text) to anon;

-- ============================================================
--  2) Auth 헬퍼: 현재 로그인한 Auth 사용자 / 허브 관리자 검증
-- ============================================================
create or replace function public._auth_uid()
returns uuid
language sql stable security definer
set search_path = public
as $$ select auth.uid() $$;
revoke all on function public._auth_uid() from anon, public;

-- 이 허브의 owner 또는 공동 admin인지 검증(아니면 예외)
create or replace function public._verify_hub_auth(p_hub_id text)
returns public.hubs
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); h public.hubs;
begin
  if v_uid is null then raise exception '허브 관리자 로그인이 필요합니다.'; end if;
  select * into h from public.hubs where hub_id = p_hub_id;
  if not found then raise exception '허브를 찾을 수 없습니다.'; end if;
  if h.owner_uid is distinct from v_uid
     and not exists (select 1 from public.hub_admins
                     where hub_id = p_hub_id and auth_uid = v_uid) then
    raise exception '이 허브의 관리자가 아닙니다.'; end if;
  return h;
end $$;
revoke all on function public._verify_hub_auth(text) from anon, public;

-- ============================================================
--  3) 허브 개설 (Auth 로그인 사용자 전용)
-- ============================================================
create or replace function public.create_hub(p_name text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); v_id text; v_code text;
        v_name text := btrim(coalesce(p_name,''));
begin
  if v_uid is null then raise exception '허브 개설에는 이메일 로그인이 필요합니다.'; end if;
  if v_name = '' then raise exception '허브 이름을 입력하세요.'; end if;
  if length(v_name) > 30 then raise exception '허브 이름은 30자 이하로 입력하세요.'; end if;

  v_id := public._next_id('H', 3, 'hubs', 'hub_id');
  v_code := upper(substring(md5(random()::text) from 1 for 6));
  insert into public.hubs(hub_id, name, invite_code, owner_uid, created_at)
  values (v_id, v_name, v_code, v_uid, to_char(now(), 'YYYY-MM-DD'));

  -- 기본 분류 시딩
  insert into public.categories(hub_id, name, sort_order) values
    (v_id,'전략',1),(v_id,'마피아',2),(v_id,'트릭테이킹',3),(v_id,'파티',4),(v_id,'협력',5),
    (v_id,'덱빌딩',6),(v_id,'추리',7),(v_id,'가족',8),(v_id,'아브스트랙트',9),(v_id,'기타',10)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code);
end $$;

-- 내가 관리(owner/공동 admin)하는 허브 목록
create or replace function public.my_hubs()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', h.hub_id, 'name', h.name,
    'is_owner', (h.owner_uid = public._auth_uid())
  ) order by h.hub_id), '[]'::json)
  from public.hubs h
  where h.owner_uid = public._auth_uid()
     or exists (select 1 from public.hub_admins a
                where a.hub_id = h.hub_id and a.auth_uid = public._auth_uid());
$$;

-- ============================================================
--  4) 허브 관리 (owner/공동 admin 전용)
-- ============================================================
create or replace function public.hub_rename(p_hub_id text, p_name text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_name text := btrim(coalesce(p_name,''));
begin
  perform public._verify_hub_auth(p_hub_id);
  if v_name = '' then raise exception '허브 이름을 입력하세요.'; end if;
  if length(v_name) > 30 then raise exception '허브 이름은 30자 이하로 입력하세요.'; end if;
  update public.hubs set name = v_name where hub_id = p_hub_id;
  return json_build_object('hub_id', p_hub_id, 'name', v_name);
end $$;

-- 초대코드 확인(관리자만 열람 가능)
create or replace function public.hub_get_invite(p_hub_id text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare h public.hubs;
begin
  h := public._verify_hub_auth(p_hub_id);
  return json_build_object('hub_id', p_hub_id, 'invite_code', h.invite_code);
end $$;

-- 초대코드 재발급(유출 시)
create or replace function public.hub_rotate_invite(p_hub_id text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_code text := upper(substring(md5(random()::text) from 1 for 6));
begin
  perform public._verify_hub_auth(p_hub_id);
  update public.hubs set invite_code = v_code where hub_id = p_hub_id;
  return json_build_object('hub_id', p_hub_id, 'invite_code', v_code);
end $$;

-- 관리자(owner) 이전: 현 owner만 가능. 새 owner는 이 허브의 공동 admin이거나
-- 계정이 연결된 멤버여야 함(아무 계정에나 넘기는 실수 방지).
create or replace function public.hub_transfer_owner(p_hub_id text, p_new_uid uuid)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); h public.hubs;
begin
  if v_uid is null then raise exception '허브 관리자 로그인이 필요합니다.'; end if;
  select * into h from public.hubs where hub_id = p_hub_id;
  if not found then raise exception '허브를 찾을 수 없습니다.'; end if;
  if h.owner_uid is distinct from v_uid then
    raise exception '현재 소유자만 이전할 수 있습니다.'; end if;
  if p_new_uid is null then raise exception '새 관리자 계정이 필요합니다.'; end if;
  if not exists (select 1 from public.hub_admins where hub_id = p_hub_id and auth_uid = p_new_uid)
     and not exists (select 1 from public.players where hub_id = p_hub_id and auth_uid = p_new_uid) then
    raise exception '새 관리자는 이 허브의 공동 관리자이거나 계정이 연결된 멤버여야 합니다.'; end if;

  update public.hubs set owner_uid = p_new_uid where hub_id = p_hub_id;
  -- 이전 owner는 공동 admin으로 남김(원하면 목록에서 제거)
  insert into public.hub_admins(hub_id, auth_uid) values (p_hub_id, v_uid)
  on conflict (hub_id, auth_uid) do nothing;
  delete from public.hub_admins where hub_id = p_hub_id and auth_uid = p_new_uid;
  return json_build_object('hub_id', p_hub_id, 'transferred', true);
end $$;

-- 공동 admin 추가/제거 (owner만)
create or replace function public.hub_set_coadmin(p_hub_id text, p_uid uuid, p_grant boolean)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); h public.hubs;
begin
  select * into h from public.hubs where hub_id = p_hub_id;
  if not found then raise exception '허브를 찾을 수 없습니다.'; end if;
  if h.owner_uid is distinct from v_uid then raise exception '소유자만 변경할 수 있습니다.'; end if;
  if p_grant then
    insert into public.hub_admins(hub_id, auth_uid) values (p_hub_id, p_uid)
    on conflict (hub_id, auth_uid) do nothing;
  else
    delete from public.hub_admins where hub_id = p_hub_id and auth_uid = p_uid;
  end if;
  return json_build_object('hub_id', p_hub_id, 'auth_uid', p_uid, 'is_admin', p_grant);
end $$;

-- ============================================================
--  5) 계정 ↔ 멤버 연결 (2-5 열쇠고리 모델의 연결 고리)
--     PIN을 아는 것 = 본인 증명. owner가 자기 멤버에 연결하면 role=admin 승격.
-- ============================================================
create or replace function public.link_player(p_hub_id text, p_player_id text, p_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := public._auth_uid(); r public.players; v_is_admin boolean;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  r := public._verify(p_player_id, p_pin);
  if r.hub_id <> p_hub_id then raise exception '이 허브의 멤버가 아닙니다.'; end if;
  if r.auth_uid is not null and r.auth_uid is distinct from v_uid then
    raise exception '이미 다른 계정에 연결된 멤버입니다.'; end if;

  v_is_admin := exists (select 1 from public.hubs
                        where hub_id = p_hub_id and owner_uid = v_uid)
             or exists (select 1 from public.hub_admins
                        where hub_id = p_hub_id and auth_uid = v_uid);

  update public.players
     set auth_uid = v_uid,
         role = case when v_is_admin then 'admin' else role end
   where player_id = p_player_id;

  return json_build_object('player_id', p_player_id, 'hub_id', p_hub_id,
                           'linked', true, 'role_admin', v_is_admin);
end $$;

-- 연결 해제(본인 계정에 연결된 멤버만)
create or replace function public.unlink_player(p_player_id text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid();
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  update public.players set auth_uid = null
   where player_id = p_player_id and auth_uid = v_uid;
  if not found then raise exception '내 계정에 연결된 멤버가 아닙니다.'; end if;
  return json_build_object('player_id', p_player_id, 'linked', false);
end $$;

-- ============================================================
--  6) 권한: Auth 전용 RPC는 authenticated 에게만
-- ============================================================
revoke all on function public.create_hub(text)                       from anon, public;
revoke all on function public.my_hubs()                              from anon, public;
revoke all on function public.hub_rename(text, text)                 from anon, public;
revoke all on function public.hub_get_invite(text)                   from anon, public;
revoke all on function public.hub_rotate_invite(text)                from anon, public;
revoke all on function public.hub_transfer_owner(text, uuid)         from anon, public;
revoke all on function public.hub_set_coadmin(text, uuid, boolean)   from anon, public;
revoke all on function public.link_player(text, text, text)          from anon, public;
revoke all on function public.unlink_player(text)                    from anon, public;

grant execute on function public.create_hub(text)                     to authenticated;
grant execute on function public.my_hubs()                            to authenticated;
grant execute on function public.hub_rename(text, text)               to authenticated;
grant execute on function public.hub_get_invite(text)                 to authenticated;
grant execute on function public.hub_rotate_invite(text)              to authenticated;
grant execute on function public.hub_transfer_owner(text, uuid)       to authenticated;
grant execute on function public.hub_set_coadmin(text, uuid, boolean) to authenticated;
grant execute on function public.link_player(text, text, text)        to authenticated;
grant execute on function public.unlink_player(text)                  to authenticated;

-- 끝. 다음 단계(2-6): 앱 UI — 첫 화면 허브/개인 분기, 허브 전환, MY 통합
