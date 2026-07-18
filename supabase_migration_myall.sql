-- ============================================================
--  마이그레이션: MY 플레이 기록·게임 기록 통합(전 허브)
--  supabase_fix_all.sql(또는 personal 마이그레이션) 실행 후에 Run.
--  여러 번 실행해도 안전.
--
--  · get_my_plays_all: 내 계정에 연결된 전 허브에서 내가 참가한
--    플레이 세션 목록 (get_plays와 동일 형태 + hub_id/hub_name)
--  · get_my_games_all: 허브×게임별 내 플레이 집계 + 내 평점
--    (앱이 범위(전체/허브별)에 맞게 합산해 게임 기록 탭에 표시)
-- ============================================================

create or replace function public.get_my_plays_all()
returns json
language sql stable security definer
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  msess as (   -- 내가 참가한 세션 (허브 포함)
    select distinct p.hub_id, p.session_id
    from public.playlogs p
    join my on my.player_id = p.player_id and my.hub_id = p.hub_id
  ),
  parts as (
    select p.hub_id, p.session_id, p.record_id,
      json_build_object(
        'record_id', p.record_id,
        'player_id', p.player_id,
        'name', coalesce(nullif(btrim(p.player_name), ''), pl.name, p.player_id),
        'is_guest', (p.player_id is null or p.player_id = '' or pl.player_id is null),
        'score', p.score,
        'is_win', coalesce(p.is_win, false)
      ) as participant
    from public.playlogs p
    join msess ms on ms.hub_id = p.hub_id and ms.session_id = p.session_id
    left join public.players pl on pl.player_id = p.player_id
  ),
  sess as (
    select s.hub_id, s.session_id, s.play_date, s.game_id, s.duration_min, s.created_by,
           g.name_kr, g.name_en, g.image_url, h.name as hub_name
    from (
      select distinct on (hub_id, session_id)
             hub_id, session_id, play_date, game_id, duration_min, created_by
      from public.playlogs p
      where exists (select 1 from msess ms
                    where ms.hub_id = p.hub_id and ms.session_id = p.session_id)
      order by hub_id, session_id, record_id
    ) s
    left join public.games g on g.game_id = s.game_id
    left join public.hubs h on h.hub_id = s.hub_id
  )
  select coalesce(json_agg(json_build_object(
    'session_id',   se.session_id,
    'hub_id',       se.hub_id,
    'hub_name',     coalesce(se.hub_name, se.hub_id),
    'play_date',    se.play_date,
    'game_id',      se.game_id,
    'game_name',    coalesce(se.name_kr, se.name_en, '(알 수 없는 게임)'),
    'game_image',   coalesce(se.image_url, ''),
    'duration_min', se.duration_min,
    'created_by',   coalesce(se.created_by, ''),
    'participants', (
      select coalesce(json_agg(pa.participant order by pa.record_id), '[]'::json)
      from parts pa where pa.hub_id = se.hub_id and pa.session_id = se.session_id
    )
  ) order by se.play_date desc, se.session_id desc), '[]'::json)
  from sess se;
$$;

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
  )
  select coalesce(json_agg(json_build_object(
    'game_id',   a.game_id,
    'hub_id',    a.hub_id,
    'hub_name',  coalesce(h.name, a.hub_id),
    'name_kr',   g.name_kr,
    'name_en',   g.name_en,
    'category',  coalesce(g.category, ''),
    'image_url', coalesce(g.image_url, ''),
    'plays',     a.plays,
    'wins',      a.wins,
    'first_rn',  a.first_rn,
    'my_rating', (select r.rating from public.ratings r
                  join my m on m.player_id = r.player_id
                  where r.game_id = a.game_id and r.hub_id = a.hub_id
                    and r.rating is not null
                  limit 1)
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;

revoke all on function public.get_my_plays_all() from anon, public;
revoke all on function public.get_my_games_all() from anon, public;
grant execute on function public.get_my_plays_all() to authenticated;
grant execute on function public.get_my_games_all() to authenticated;
