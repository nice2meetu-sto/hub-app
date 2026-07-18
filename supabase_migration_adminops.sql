-- ============================================================
--  마이그레이션: 관리자 넘기기(2-3) + 허브 탈퇴 처리(2-5)
--  supabase_migration_searchnorm.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hub_transfer_owner_to_player: 가입자 목록에서 멤버를 지정해
--    관리자 이전(대상은 이메일 연결 멤버). 이전 관리자는 공동 관리자로 잔류
--  · admin_set_left: 관리자가 멤버를 소프트 탈퇴(status='left') / 복귀 처리
--    — 기록·통계 보존, 멤버 목록·자동완성·로그인에서만 제외
--  · admin_get_players: 탈퇴 멤버도 status와 함께 반환(복귀 처리용)
-- ============================================================

-- 관리자 이전(멤버 지정): 현 소유자 로그인 상태에서만. 대상의 role도 admin으로
create or replace function public.hub_transfer_owner_to_player(p_hub_id text, p_player_id text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_new uuid;
begin
  select auth_uid into v_new from public.players
   where player_id = p_player_id and hub_id = p_hub_id;
  if not found then raise exception '이 허브의 멤버가 아닙니다.'; end if;
  if v_new is null then
    raise exception '대상 멤버가 이메일 계정에 연결되어 있어야 합니다.'; end if;
  perform public.hub_transfer_owner(p_hub_id, v_new);   -- 소유자 검증 포함
  update public.players set role = 'admin' where player_id = p_player_id;
  return json_build_object('hub_id', p_hub_id, 'player_id', p_player_id, 'transferred', true);
end $$;
revoke all on function public.hub_transfer_owner_to_player(text, text) from anon, public;
grant execute on function public.hub_transfer_owner_to_player(text, text) to authenticated;

-- 멤버 탈퇴/복귀 처리(관리자 전용, 소프트 탈퇴)
create or replace function public.admin_set_left(
  p_player_id text, p_pin text, p_target_id text, p_left boolean)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; t public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  select * into t from public.players
   where player_id = p_target_id and hub_id = v_auth.hub_id;
  if not found then raise exception '멤버를 찾을 수 없습니다.'; end if;
  if p_left and t.player_id = v_auth.player_id then
    raise exception '자기 자신은 탈퇴 처리할 수 없습니다.'; end if;
  if p_left and t.auth_uid is not null
     and exists (select 1 from public.hubs
                 where hub_id = v_auth.hub_id and owner_uid = t.auth_uid) then
    raise exception '허브 개설 계정의 멤버는 탈퇴 처리할 수 없습니다. (관리자 넘기기 후 가능)'; end if;

  update public.players
     set status = case when p_left then 'left' else 'active' end
   where player_id = p_target_id;
  return json_build_object('player_id', p_target_id,
                           'status', case when p_left then 'left' else 'active' end);
end $$;
grant execute on function public.admin_set_left(text, text, text, boolean) to anon;
grant execute on function public.admin_set_left(text, text, text, boolean) to authenticated;

-- 가입자 목록: 탈퇴 멤버 포함 + status (활동 멤버 먼저)
create or replace function public.admin_get_players(p_player_id text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  return (select coalesce(json_agg(json_build_object(
    'player_id', player_id, 'name', name, 'pin', coalesce(pin, ''),
    'role', coalesce(role, 'member'), 'joined_at', coalesce(joined_at, ''),
    'status', coalesce(status, 'active')
  ) order by (coalesce(status,'active') = 'left'), player_id), '[]'::json)
  from public.players
  where hub_id = v_auth.hub_id);
end $$;
