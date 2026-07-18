-- ============================================================
--  마이그레이션: 게임명 중복 기준에 '띄어쓰기 무시' 추가
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.
--
--  add_game 의 중복 검사 시 공백을 모두 제거하고 비교하여,
--  "매직 넘버 일레븐" 과 "매직넘버일레븐" 을 같은 게임으로 취급해 거부합니다.
--  (대소문자도 무시)
-- ============================================================

create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id text; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_name text := btrim(coalesce(p_payload->>'name_kr',''));
        v_key  text := regexp_replace(lower(btrim(coalesce(p_payload->>'name_kr',''))), '\s+', '', 'g');
begin
  perform public._verify(p_player_id, p_pin);
  if v_name = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if exists (select 1 from public.games
             where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g') = v_key) then
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

grant execute on function public.add_game(text, text, jsonb) to anon;
