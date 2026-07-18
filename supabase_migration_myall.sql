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
                  where r.game_id = a.game_id and r.hub_id = a.hub_id
                    and r.rating is not null
                  limit 1),
    -- 전체 평점/후기: 공용 도감 기준, 모든 허브 이용자 집계
    'all_rating', (select round(avg(r.rating)::numeric, 1) from public.ratings r
                   where r.game_id = a.game_id and r.rating is not null),
    'all_rating_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id and r.rating is not null),
    'all_review_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id
                           and r.review is not null and btrim(r.review) <> '')
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;

-- 게임의 전체 후기(모든 허브) — 공용 도감 기준 모아보기용.
-- get_reviews(허브 범위)와 동일 형태 + hub_name
create or replace function public.get_reviews_all(p_game_id text)
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
    and r.review is not null and btrim(r.review) <> '';
$$;

-- 안전장치: 한 계정은 한 허브에 멤버 1명만 연결 가능(중복 연결 금지)
create or replace function public.link_player(p_hub_id text, p_player_id text, p_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := public._auth_uid(); r public.players; v_is_admin boolean;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  r := public._verify(p_player_id, p_pin);
  if r.hub_id <> p_hub_id then raise exception '이 허브의 멤버가 아닙니다.'; end if;
  if r.auth_uid is not null and r.auth_uid is distinct from v_uid then
    raise exception '이미 다른 계정에 연결된 멤버입니다.'; end if;
  if exists (select 1 from public.players
             where hub_id = p_hub_id and auth_uid = v_uid
               and player_id <> p_player_id) then
    raise exception '이미 연결된 허브예요.'; end if;

  v_is_admin := exists (select 1 from public.hubs
                        where hub_id = p_hub_id and owner_uid = v_uid)
             or exists (select 1 from public.hub_admins
                        where hub_id = p_hub_id and auth_uid = v_uid);

  update public.players
     set auth_uid = v_uid,
         role = case when v_is_admin then 'admin' else role end
   where player_id = p_player_id;

  return json_build_object('player_id', p_player_id, 'hub_id', p_hub_id,
                           'linked', true, 'role_admin', v_is_admin);
end $$;

-- get_my_links에 초대코드 포함(허브 전환 메뉴에서 초대 문구 복사용)
create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name, 'kind', coalesce(h.kind,'hub'),
    'invite', coalesce(h.invite_code, ''),
    'player_id', p.player_id, 'name', p.name,
    'status', coalesce(p.status,'active')
  ) order by (coalesce(h.kind,'hub') = 'personal') desc, p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid();
$$;

revoke all on function public.get_my_plays_all() from anon, public;
revoke all on function public.get_my_games_all() from anon, public;
grant execute on function public.get_my_plays_all() to authenticated;
grant execute on function public.get_my_games_all() to authenticated;
grant execute on function public.get_reviews_all(text) to anon;
grant execute on function public.get_reviews_all(text) to authenticated;
