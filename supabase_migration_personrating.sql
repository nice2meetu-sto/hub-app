-- ============================================================
--  마이그레이션: 평점·후기·메모를 '사람×게임' 기준으로 통합
--  supabase_migration_myall.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · 게임은 공용 도감이므로 평점/후기/메모도 허브와 무관하게
--    (게임, 사람) 단위로 하나만 존재
--  · '사람' = 같은 이메일 계정(auth_uid)에 연결된 멤버들은 한 사람.
--    연결 없는 멤버는 player_id 그대로가 한 사람
--  · 읽기: 게임 평점 = 전체 이용자 평균, 후기 = 전체 후기
--  · 쓰기: 같은 사람의 기존 행이 있으면 그 행을 갱신(중복 생성 방지)
-- ============================================================

-- 0) 같은 사람(계정)의 형제 멤버들이 남긴 중복 행 병합
--    (최근 행을 남기고, 비어있는 필드는 다른 행에서 채운 뒤 삭제)
do $$
declare rec record; keep text;
begin
  for rec in
    select p.auth_uid, r.game_id,
           array_agg(r.player_id order by r.updated_at desc nulls last) as pids
    from public.ratings r
    join public.players p on p.player_id = r.player_id
    where p.auth_uid is not null
    group by p.auth_uid, r.game_id
    having count(*) > 1
  loop
    keep := rec.pids[1];
    update public.ratings k set
      rating = coalesce(k.rating,
        (select r2.rating from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and r2.rating is not null
          order by r2.updated_at desc nulls last limit 1)),
      review = coalesce(nullif(btrim(coalesce(k.review,'')),''),
        (select r2.review from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and coalesce(btrim(r2.review),'') <> ''
          order by r2.updated_at desc nulls last limit 1)),
      memo = coalesce(nullif(btrim(coalesce(k.memo,'')),''),
        (select r2.memo from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and coalesce(btrim(r2.memo),'') <> ''
          order by r2.updated_at desc nulls last limit 1))
    where k.game_id = rec.game_id and k.player_id = keep;
    delete from public.ratings
     where game_id = rec.game_id and player_id = any(rec.pids) and player_id <> keep;
  end loop;
end $$;

-- 1) 같은 사람의 기존 평점 행 주인 찾기(없으면 본인)
create or replace function public._rating_owner(p_player_id text, p_game_id text)
returns text
language sql stable
set search_path = public
as $$
  select coalesce(
    (select r.player_id from public.ratings r
      where r.game_id = p_game_id
        and r.player_id in (
          select p2.player_id from public.players p1
          join public.players p2 on p2.auth_uid = p1.auth_uid
          where p1.player_id = p_player_id and p1.auth_uid is not null)
      order by r.updated_at desc nulls last limit 1),
    p_player_id);
$$;

-- 2) 쓰기: 사람 단위 한 행에 저장
create or replace function public.save_rating(
  p_player_id text, p_pin text, p_game_id text, p_rating numeric)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if p_rating is null or p_rating < 1 or p_rating > 10 then
    raise exception '평점은 1~10 사이여야 합니다.'; end if;
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, rating, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, p_rating, v_now)
  on conflict (player_id, game_id) do update
    set rating = excluded.rating, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'rating', p_rating, 'updated_at', v_now);
end $$;

create or replace function public.save_review(
  p_player_id text, p_pin text, p_game_id text, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, review, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, coalesce(p_review, ''), v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;

create or replace function public.save_memo(
  p_player_id text, p_pin text, p_game_id text, p_memo text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, memo, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, coalesce(p_memo, ''), v_now)
  on conflict (player_id, game_id) do update
    set memo = excluded.memo, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'memo', coalesce(p_memo, ''));
end $$;

-- 3) 읽기: 게임 평점/후기 = 전체 이용자 기준 (허브 필터 제거)
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
    from public.ratings group by game_id
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

-- get_reviews: 전체 후기(허브 인자는 호환용으로 무시, 허브명 포함)
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select public.get_reviews_all(p_game_id);
$$;

-- get_my_ratings: 같은 사람(계정 형제 멤버)의 행까지 포함해 반환
create or replace function public.get_my_ratings(p_player_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id',    r.game_id,
    'game',       coalesce(g.name_kr, g.name_en, r.game_id),
    'rating',     r.rating,
    'memo',       coalesce(r.memo, ''),
    'review',     coalesce(r.review, ''),
    'updated_at', r.updated_at
  )), '[]'::json)
  from public.ratings r
  left join public.games g on g.game_id = r.game_id
  where r.player_id = p_player_id
     or r.player_id in (
       select p2.player_id from public.players p1
       join public.players p2 on p2.auth_uid = p1.auth_uid
       where p1.player_id = p_player_id and p1.auth_uid is not null);
$$;

-- 4) get_my_games_all: 내 평점을 허브와 무관하게(사람 기준) 조회
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
                  where r.game_id = a.game_id and r.rating is not null
                  order by r.updated_at desc nulls last limit 1),
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
