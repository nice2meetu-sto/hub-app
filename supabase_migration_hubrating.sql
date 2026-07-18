-- ============================================================
--  마이그레이션: 평점·후기 표시 범위 정리
--  supabase_migration_personrating.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  저장은 사람×게임 1개(personrating) 그대로. 보이는 범위만 정리:
--  · 허브 게임탭: 우리 허브 가입자('사람' 기준)의 평점·후기만 —
--    가입자가 다른 허브에서 남긴 것도 그 사람 것이므로 포함
--  · 기록장: 나와 같은 세션에서 게임한 사람들(+나)의 평점·후기만
-- ============================================================

-- 허브 가입자를 '사람' 단위로 확장한 player_id 목록
-- (가입자의 계정에 연결된 다른 허브 멤버 id 포함 — 평점 행 주인이
--  어느 허브 멤버로 저장돼 있어도 그 사람이면 잡히도록)
create or replace function public._hub_person_ids(p_hub_id text)
returns table(player_id text)
language sql stable
set search_path = public
as $$
  select p.player_id from public.players p where p.hub_id = p_hub_id
  union
  select p2.player_id
  from public.players p1
  join public.players p2 on p2.auth_uid = p1.auth_uid
  where p1.hub_id = p_hub_id and p1.auth_uid is not null;
$$;

-- 게임탭: ★ = 우리 허브 가입자 기준 평점/후기 수
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
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', coalesce(g.category, ''), 'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.hub_games hg
  join public.games g on g.game_id = hg.game_id
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id
  where hg.hub_id = p_hub_id;
$$;

-- 후기: 우리 허브 가입자의 후기만 (남긴 곳 허브명 포함)
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at,
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from public._hub_person_ids(p_hub_id));
$$;

-- 나와 같은 세션에서 게임한 사람들(+나)을 '사람' 단위로 확장한 id 목록
create or replace function public._my_mate_ids()
returns table(player_id text)
language sql stable
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  my_sess as (
    select distinct pl.hub_id, pl.session_id
    from public.playlogs pl
    join my on my.player_id = pl.player_id and my.hub_id = pl.hub_id
  ),
  mates_raw as (
    select distinct pl.player_id
    from public.playlogs pl
    join my_sess ms on ms.hub_id = pl.hub_id and ms.session_id = pl.session_id
    where coalesce(pl.player_id, '') <> ''
  )
  select player_id from mates_raw
  union
  select p2.player_id
  from mates_raw mr
  join public.players p1 on p1.player_id = mr.player_id and p1.auth_uid is not null
  join public.players p2 on p2.auth_uid = p1.auth_uid
  union
  select player_id from my;
$$;

-- 기록장 후기 보기: 나와 게임한 사람들의 후기만
create or replace function public.get_reviews_mates(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at,
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from public._my_mate_ids());
$$;
revoke all on function public.get_reviews_mates(text) from anon, public;
grant execute on function public.get_reviews_mates(text) to authenticated;

-- 기록장 게임 카드: all_rating 계열 = 나와 게임한 사람들 기준
create or replace function public.get_my_games_all()
returns json
language sql stable security definer
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  logs as (
    select p.hub_id, p.game_id, p.is_win,
           row_number() over (order by p.play_date desc, p.record_id desc) as rn
    from public.playlogs p
    join my on my.player_id = p.player_id and my.hub_id = p.hub_id
  ),
  agg as (
    select hub_id, game_id, count(*) as plays,
           count(*) filter (where is_win) as wins,
           min(rn) as first_rn
    from logs group by hub_id, game_id
  ),
  mates as (select player_id from public._my_mate_ids())
  select coalesce(json_agg(json_build_object(
    'game_id',   a.game_id,
    'hub_id',    a.hub_id,
    'hub_name',  coalesce(h.name, a.hub_id),
    'name_kr',   g.name_kr,
    'name_en',   g.name_en,
    'category',  coalesce(g.category, ''),
    'image_url', coalesce(g.image_url, ''),
    'min_players',  g.min_players,
    'max_players',  g.max_players,
    'playtime_min', g.playtime_min,
    'weight',       g.weight,
    'summary_kr',   coalesce(g.summary_kr, ''),
    'plays',     a.plays,
    'wins',      a.wins,
    'first_rn',  a.first_rn,
    'my_rating', (select r.rating from public.ratings r
                  join my m on m.player_id = r.player_id
                  where r.game_id = a.game_id and r.rating is not null
                  order by r.updated_at desc nulls last limit 1),
    'all_rating', (select round(avg(r.rating)::numeric, 1) from public.ratings r
                   where r.game_id = a.game_id and r.rating is not null
                     and r.player_id in (select player_id from mates)),
    'all_rating_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id and r.rating is not null
                           and r.player_id in (select player_id from mates)),
    'all_review_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id
                           and r.review is not null and btrim(r.review) <> ''
                           and r.player_id in (select player_id from mates))
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;
