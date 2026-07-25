-- ============================================================
--  마이그레이션: 허브에서 게임 삭제 시 공용 도감(games)은 보존
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  문제
--    · 기존 admin_delete_game 은 그 게임을 선반에 둔 허브가 하나도 남지
--      않으면(v_left=0) 공용 도감 games 행까지 삭제 → 방금 추가한 게임을
--      한 허브에서 지우면 도감에서도 사라져 버림.
--
--  수정
--    · 허브 선반(hub_games)과 그 허브의 평점(ratings)만 삭제.
--    · 공용 도감(games)은 절대 건드리지 않음 → 도감에는 계속 보임.
--    · 플레이 기록(playlogs)은 그대로 보존(기존과 동일).
-- ============================================================

create or replace function public.admin_delete_game(p_player_id text, p_pin text, p_game_id text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  if coalesce(p_game_id,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.hub_games
                 where hub_id = v_auth.hub_id and game_id = p_game_id) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

  -- 이 허브 선반에서만 제거 + 이 허브의 평점만 제거. 공용 도감(games)은 유지.
  delete from public.ratings   where game_id = p_game_id and hub_id = v_auth.hub_id;
  delete from public.hub_games where game_id = p_game_id and hub_id = v_auth.hub_id;

  return json_build_object('game_id', p_game_id, 'deleted', true, 'catalog_removed', false);
end $$;
grant execute on function public.admin_delete_game(text, text, text) to anon;
