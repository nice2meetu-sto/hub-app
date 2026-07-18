-- ============================================================
--  마이그레이션: UI 개편용 보조 RPC (ROADMAP 2-6)
--  supabase_migration_auth.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hub_by_invite: 초대코드로 허브 찾기(입장 흐름의 시작점).
--    코드를 아는 사람에게만 허브 이름을 알려줌 — 목록 노출 없음
-- ============================================================

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
   where upper(invite_code) = upper(btrim(p_code));
  if not found then raise exception '초대코드가 올바르지 않습니다.'; end if;
  return json_build_object('hub_id', h.hub_id, 'name', h.name);
end $$;

grant execute on function public.hub_by_invite(text) to anon;
grant execute on function public.hub_by_invite(text) to authenticated;
