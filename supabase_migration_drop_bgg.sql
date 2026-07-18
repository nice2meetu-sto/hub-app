-- ============================================================
--  마이그레이션: BGG 관련 컬럼(bgg_id) 제거 반영
--  games 테이블에서 bgg_id 컬럼을 지운 뒤 실행하세요.
--  (이 스크립트가 컬럼 삭제도 겸하므로, 아직 안 지웠어도 그냥 실행하면 됩니다)
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.
--
--  bgg_id를 참조하던 함수 3개(get_games / add_game / update_game)를
--  bgg 필드 없이 재생성합니다. bgg_rating도 미사용이라 함수에서 함께 제거
--  (컬럼 자체는 남겨둬도 무방 — 지우고 싶으면 맨 아래 주석 해제)
-- ============================================================

alter table public.games drop column if exists bgg_id;

-- 게임 목록 (bgg 필드 제외)
create or replace function public.get_games()
returns json
language sql stable security definer
set search_path = public
as $$
  with rt as (
    select game_id, round(avg(rating)::numeric, 1) as club_rating, count(*) as rating_count
    from public.ratings where rating is not null group by game_id
  ),
  pc as (
    select game_id, count(distinct session_id) as play_count
    from public.playlogs group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', g.category, 'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.games g
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id;
$$;

-- 게임 추가 (bgg 필드 제외)
create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id text; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  v_id := public._next_id('G', 3, 'games', 'game_id');

  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, playtime_min, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id,
    coalesce(p_payload->>'name_kr',''), coalesce(p_payload->>'name_en',''),
    coalesce(p_payload->>'category',''),
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );

  return json_build_object('game_id', v_id, 'name_kr', coalesce(p_payload->>'name_kr',''), 'source', 'manual');
end $$;

-- 게임 수정 (bgg 필드 제외, 관리자만)
create or replace function public.update_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_role text; v_gid text;
begin
  perform public._verify(p_player_id, p_pin);
  select role into v_role from public.players where player_id = p_player_id;
  if coalesce(v_role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;

  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.games where game_id = v_gid) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

  update public.games set
    name_kr   = coalesce(p_payload->>'name_kr', name_kr),
    name_en   = coalesce(p_payload->>'name_en', name_en),
    category  = coalesce(p_payload->>'category', category),
    min_players  = case when p_payload ? 'min_players'  then nullif(p_payload->>'min_players','')::numeric  else min_players end,
    max_players  = case when p_payload ? 'max_players'  then nullif(p_payload->>'max_players','')::numeric  else max_players end,
    playtime_min = case when p_payload ? 'playtime_min' then nullif(p_payload->>'playtime_min','')::numeric else playtime_min end,
    weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
    summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
    image_url  = coalesce(p_payload->>'image_url', image_url)
  where game_id = v_gid;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;

grant execute on function public.get_games()                     to anon;
grant execute on function public.add_game(text, text, jsonb)     to anon;
grant execute on function public.update_game(text, text, jsonb)  to anon;

-- (선택) bgg_rating 컬럼도 안 쓰므로 지우고 싶으면 아래 주석을 풀고 실행하세요.
-- alter table public.games drop column if exists bgg_rating;
