-- ============================================================
--  마이그레이션: 관리자-게임 탭에 '이 허브에 추가한 사람' 표시
--  supabase_migration_gameedit.sql 이후에 Run. 여러 번 실행해도 안전.
--
--  get_games가 hub_games.added_by(허브 선반에 올린 사람)와
--  added_by_name(그 사람의 이 허브 닉네임, 연동 계정이면 연동 닉네임 우선,
--  없으면 본인 이름)을 함께 반환한다. 프론트는 관리자-게임 탭 카드의
--  썸네일 아래에 닉네임 배지로 표시.
-- ============================================================

create or replace function public.get_games(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  with rt as (
    select game_id,
           round(avg(rating) filter (where rating is not null)::numeric, 1) as club_rating,
           count(*) filter (where rating is not null) as rating_count,
           count(*) filter (where review is not null and btrim(review) <> '') as review_count
    from public.ratings
    where player_id in (select player_id from public._hub_person_ids(p_hub_id))
    group by game_id
  ),
  pc as (
    select game_id, count(distinct session_id) as play_count
    from public.playlogs where hub_id = p_hub_id group by game_id
  ),
  sh as (
    select game_id, count(distinct hub_id) as hub_cnt
    from public.hub_games group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', coalesce(nullif(hg.category,''), g.category, ''),
    'catalog_category', coalesce(g.category, ''),
    'added_at', coalesce(hg.added_at, ''),
    'added_by', coalesce(hg.added_by, ''),
    'added_by_name', coalesce(
      (select lp.name from public.players lp
        where lp.hub_id = p_hub_id
          and (lp.player_id = hg.added_by
               or (ab.auth_uid is not null and lp.auth_uid = ab.auth_uid))
        order by lp.player_id limit 1), ab.name, ''),
    'min_players', g.min_players, 'max_players', g.max_players,
    'best_players', g.best_players,
    'playtime_min', g.playtime_min, 'min_playtime', g.min_playtime, 'max_playtime', g.max_playtime,
    'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'created_by', coalesce(g.created_by, ''),
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0),
    'shared', coalesce(sh.hub_cnt, 1) > 1
  ) order by g.game_id), '[]'::json)
  from public.hub_games hg
  join public.games g on g.game_id = hg.game_id
  left join public.players ab on ab.player_id = hg.added_by
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id
  left join sh on sh.game_id = g.game_id
  where hg.hub_id = p_hub_id;
$$;
