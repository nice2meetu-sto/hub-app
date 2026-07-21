-- ============================================================
--  마이그레이션: 허브 삭제(소프트 삭제)
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  요구사항
--    · 관리자가 허브를 삭제하면 그 허브는 초대·로그인·허브 목록에서 사라짐.
--    · 단, players / playlogs / ratings 기록은 그대로 보존 →
--      이메일로 연동한 회원은 본인 개인 기록장(get_my_plays_all /
--      get_my_games_all)에서 지난 기록을 계속 열람할 수 있음.
--
--  구현
--    · hubs.deleted_at 컬럼 추가(소프트 삭제 표시). 행 자체는 남겨
--      개인 기록 뷰의 허브 이름(hub_name)이 계속 보이게 한다.
--    · delete_hub(관리자 PIN 전용): 해당 허브에 deleted_at 표시만.
--      기록 테이블은 건드리지 않음.
--    · 입장/목록 함수는 deleted_at 이 있는 허브를 제외하도록 갱신:
--        hub_by_invite / login / login_linked / my_hubs / get_my_links
-- ============================================================

alter table public.hubs add column if not exists deleted_at text;

-- ---- 허브 삭제(관리자 PIN 전용, 소프트 삭제) ------------------
create or replace function public.delete_hub(p_player_id text, p_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_kind text;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);   -- 관리자 확인(실패 시 예외)
  select coalesce(kind, 'hub') into v_kind from public.hubs where hub_id = v_auth.hub_id;
  if v_kind = 'personal' then
    raise exception '개인 기록장은 삭제할 수 없습니다.';
  end if;
  update public.hubs
     set deleted_at = to_char(now(), 'YYYY-MM-DD HH24:MI:SS')
   where hub_id = v_auth.hub_id and deleted_at is null;
  -- players / playlogs / ratings 는 보존(개인 기록장 열람용)
  return json_build_object('ok', true, 'hub_id', v_auth.hub_id);
end $$;
revoke all on function public.delete_hub(text, text) from public;
grant execute on function public.delete_hub(text, text) to anon;

-- ---- 입장/목록 함수: 삭제된 허브 제외 ------------------------

-- 초대코드로 허브 확인 → 삭제된 허브는 코드가 있어도 못 찾음
create or replace function public.hub_by_invite(p_code text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare h public.hubs;
begin
  if btrim(coalesce(p_code,'')) = '' then
    raise exception '초대코드를 입력하세요.'; end if;
  select * into h from public.hubs
   where upper(invite_code) = upper(btrim(p_code)) and deleted_at is null;
  if not found then raise exception '초대코드가 올바르지 않습니다.'; end if;
  return json_build_object('hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
                           'icon', coalesce(h.icon,''));
end $$;

-- 닉네임+PIN 로그인 → 삭제된 허브는 거부(최근 허브 원탭 재입장 포함)
create or replace function public.login(p_name text, p_pin text, p_hub_id text default 'H001')
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  if coalesce(p_name,'') = '' or coalesce(p_pin,'') = '' then
    raise exception '이름과 PIN을 입력하세요.'; end if;
  if exists (select 1 from public.hubs where hub_id = p_hub_id and deleted_at is not null) then
    raise exception '삭제된 허브입니다.'; end if;
  select * into r from public.players
   where hub_id = p_hub_id and lower(btrim(name)) = lower(btrim(p_name));
  if not found then raise exception '사용자를 찾을 수 없습니다.'; end if;
  if coalesce(r.status, 'active') = 'left' then
    raise exception '탈퇴한 회원입니다.'; end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then
    raise exception 'PIN 입력이 잠시 잠겼습니다. 잠시 후 다시 시도하세요.'; end if;
  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then raise exception 'PIN이 올바르지 않습니다.'; end if;
  return json_build_object('player_id', r.player_id, 'name', r.name,
                           'role', coalesce(r.role,'member'), 'hub_id', r.hub_id);
end $$;
grant execute on function public.login(text, text, text) to anon;

-- 이메일 연동 자동 로그인 → 삭제된 허브는 거부
create or replace function public.login_linked(p_hub_id text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); r public.players;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  if exists (select 1 from public.hubs where hub_id = p_hub_id and deleted_at is not null) then
    raise exception '삭제된 허브입니다.'; end if;
  select * into r from public.players
   where hub_id = p_hub_id and auth_uid = v_uid and coalesce(status,'active') <> 'left'
   order by player_id limit 1;
  if not found then raise exception '이 허브에 연결된 멤버가 없습니다.'; end if;
  return json_build_object('player_id', r.player_id, 'name', r.name,
                           'role', coalesce(r.role,'member'), 'hub_id', r.hub_id,
                           'pin', coalesce(r.pin, ''));
end $$;
revoke all on function public.login_linked(text) from anon, public;
grant execute on function public.login_linked(text) to authenticated;

-- 이메일 계정이 개설·관리하는 허브 목록 → 삭제된 허브 제외
create or replace function public.my_hubs()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
    'icon', coalesce(h.icon,''),
    'is_owner', (h.owner_uid = public._auth_uid())
  ) order by h.hub_id), '[]'::json)
  from public.hubs h
  where h.deleted_at is null
    and (h.owner_uid = public._auth_uid()
      or exists (select 1 from public.hub_admins a
                 where a.hub_id = h.hub_id and a.auth_uid = public._auth_uid()));
$$;

-- 이메일 계정에 연결된 멤버(허브 이동 목록) → 삭제된 허브 제외.
-- (지난 기록은 get_my_plays_all / get_my_games_all 로 개인 기록장에서 계속 열람됨)
create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name, 'kind', coalesce(h.kind,'hub'),
    'icon', coalesce(h.icon,''),
    'invite', coalesce(h.invite_code, ''),
    'player_id', p.player_id, 'name', p.name, 'pin', coalesce(p.pin, ''),
    'status', coalesce(p.status,'active')
  ) order by (coalesce(h.kind,'hub') = 'personal') desc, p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid() and h.deleted_at is null;
$$;
