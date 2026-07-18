-- ============================================================
--  마이그레이션: 게임 삭제(관리자) + 게임명 중복 방지
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.
--
--   - add_game : 같은 한글명이 이미 있으면 등록 거부(닉네임처럼)
--   - admin_delete_game(신규) : 게임 + 연관 평점/후기 삭제 (관리자 전용)
--     ※ 플레이 기록(playlogs)은 보존합니다(게임명은 남아 있음).
-- ============================================================

-- 게임 추가: 한글명 중복 방지
create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id text; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_name text := btrim(coalesce(p_payload->>'name_kr',''));
begin
  perform public._verify(p_player_id, p_pin);
  if v_name = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if exists (select 1 from public.games where btrim(name_kr) = v_name) then
    raise exception '이미 등록된 게임명입니다.'; end if;

  v_id := public._next_id('G', 3, 'games', 'game_id');
  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, playtime_min, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id, v_name, coalesce(p_payload->>'name_en',''),
    coalesce(p_payload->>'category',''),
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );
  return json_build_object('game_id', v_id, 'name_kr', v_name, 'source', 'manual');
end $$;

-- 게임 삭제(관리자 전용): 게임 + 그 게임의 평점/후기 삭제. 플레이 기록은 보존.
create or replace function public.admin_delete_game(p_player_id text, p_pin text, p_game_id text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public._verify_admin(p_player_id, p_pin);
  if coalesce(p_game_id,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.games where game_id = p_game_id) then
    raise exception '게임을 찾을 수 없습니다.'; end if;
  delete from public.ratings where game_id = p_game_id;
  delete from public.games   where game_id = p_game_id;
  return json_build_object('game_id', p_game_id, 'deleted', true);
end $$;

grant execute on function public.add_game(text, text, jsonb)               to anon;
grant execute on function public.admin_delete_game(text, text, text)       to anon;
