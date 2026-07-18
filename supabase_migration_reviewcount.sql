-- ============================================================
--  마이그레이션: 게임 목록에 후기 개수(review_count) 추가
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.
--
--  get_games 가 이미 훑는 ratings 테이블에 집계 한 줄을 얹는 것뿐이라
--  로딩 부담 없이 후기 개수를 함께 반환합니다(빈 후기는 제외).
-- ============================================================

create or replace function public.get_games()
returns json
language sql stable security definer
set search_path = public
as $$
  with rt as (
    select game_id,
           round(avg(rating) filter (where rating is not null)::numeric, 1) as club_rating,
           count(*) filter (where rating is not null) as rating_count,
           count(*) filter (where review is not null and btrim(review) <> '') as review_count
    from public.ratings group by game_id
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
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.games g
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id;
$$;

grant execute on function public.get_games() to anon;
