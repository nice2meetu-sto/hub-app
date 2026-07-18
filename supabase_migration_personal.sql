-- ============================================================
--  마이그레이션: 개인 기록장 규칙 + 연결 계정 자동 로그인
--  supabase_migration_linked.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hubs.kind ('hub' | 'personal') 구분 추가
--  · create_hub: 개인 기록장은 계정당 1개 — 이미 있으면 새로 만들지 않고
--    기존 기록장을 반환(existing: true) → 앱이 그리로 재입장
--  · login_linked: 계정에 연결된 멤버로 PIN 없이 로그인(기기 변경/재입장용.
--    이메일 인증이 PIN보다 강한 증명이므로 안전)
-- ============================================================

alter table public.hubs add column if not exists kind text default 'hub';

drop function if exists public.create_hub(text);
create or replace function public.create_hub(p_name text, p_kind text default 'hub')
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); v_id text; v_code text; h public.hubs;
        v_name text := btrim(coalesce(p_name,''));
        v_kind text := case when p_kind = 'personal' then 'personal' else 'hub' end;
begin
  if v_uid is null then raise exception '허브 개설에는 이메일 로그인이 필요합니다.'; end if;
  if v_name = '' then raise exception '허브 이름을 입력하세요.'; end if;
  if length(v_name) > 30 then raise exception '허브 이름은 30자 이하로 입력하세요.'; end if;

  -- 개인 기록장은 계정당 1개: 이미 있으면 그 기록장을 반환
  if v_kind = 'personal' then
    select * into h from public.hubs
     where owner_uid = v_uid and kind = 'personal'
     order by hub_id limit 1;
    if found then
      return json_build_object('hub_id', h.hub_id, 'name', h.name,
                               'invite_code', h.invite_code, 'existing', true);
    end if;
  end if;

  v_id := public._next_id('H', 3, 'hubs', 'hub_id');
  v_code := upper(substring(md5(random()::text) from 1 for 6));
  insert into public.hubs(hub_id, name, invite_code, owner_uid, created_at, kind)
  values (v_id, v_name, v_code, v_uid, to_char(now(), 'YYYY-MM-DD'), v_kind);

  insert into public.categories(hub_id, name, sort_order) values
    (v_id,'전략',1),(v_id,'마피아',2),(v_id,'트릭테이킹',3),(v_id,'파티',4),(v_id,'협력',5),
    (v_id,'덱빌딩',6),(v_id,'추리',7),(v_id,'가족',8),(v_id,'아브스트랙트',9),(v_id,'기타',10)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code, 'existing', false);
end $$;
revoke all on function public.create_hub(text, text) from anon, public;
grant execute on function public.create_hub(text, text) to authenticated;

-- 연결된 멤버로 로그인(PIN 불요). 앱 쓰기 RPC용 pin도 함께 반환
-- (관리자 페이지가 이미 PIN을 노출하는 현 모델과 동일 수준의 접근)
create or replace function public.login_linked(p_hub_id text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); r public.players;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
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

-- my_hubs에 kind 포함(개인 기록장 구분 표시용)
create or replace function public.my_hubs()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
    'is_owner', (h.owner_uid = public._auth_uid())
  ) order by h.hub_id), '[]'::json)
  from public.hubs h
  where h.owner_uid = public._auth_uid()
     or exists (select 1 from public.hub_admins a
                where a.hub_id = h.hub_id and a.auth_uid = public._auth_uid());
$$;
