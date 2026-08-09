-- ============================================================
--  마이그레이션: 게임 삭제 시 평점·후기 보존 + '선반 기준' 숨김 (방법 2)
--  supabase_migration_adminratings2.sql, supabase_migration_reviewtab2.sql
--  이후에 Run. 여러 번 실행해도 안전.
--
--  · admin_delete_game: 이제 hub_games(선반)만 삭제 — ratings는 보존.
--    재추가하면 예전 평점·후기가 자동으로 다시 보인다(복구 작업 불필요).
--  · 숨김 규칙: 후기·평점 '모아보기' 조회는 게임이 지금 선반에 있을 때만 표시.
--      - get_all_reviews / get_all_ratings: 그 허브 선반 기준
--      - get_reviews_mates / get_all_reviews_mates: 후기를 쓴 허브의 선반 기준
--        (hub_id 없는 옛 데이터는 그대로 표시)
--  · MY 탭의 내 평점·후기(get_my_ratings 등)는 건드리지 않음 — 계속 보임.
-- ============================================================

-- ---- 1) 게임 삭제: 선반만 제거, 평점·후기·플레이 기록 모두 보존 ----
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

  -- 선반에서만 제거. 평점·후기(ratings)는 보존 — 선반 기준 숨김으로 자동 감춰지고,
  -- 재추가 시 자동 복귀. 공용 도감(games)·플레이 기록(playlogs)도 유지.
  delete from public.hub_games where game_id = p_game_id and hub_id = v_auth.hub_id;

  return json_build_object('game_id', p_game_id, 'deleted', true, 'catalog_removed', false);
end $$;
grant execute on function public.admin_delete_game(text, text, text) to anon;

-- ---- 2) 후기 탭(허브): 지금 선반에 있는 게임의 후기만 ----
create or replace function public.get_all_reviews(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'player_id',   r.player_id,
    'player_name', coalesce(
      (select lp.name from public.players lp
        where lp.hub_id = p_hub_id
          and (lp.player_id = r.player_id
               or (pl.auth_uid is not null and lp.auth_uid = pl.auth_uid))
        order by lp.player_id limit 1), pl.name, '익명'),
    'game_id',     r.game_id,
    'game_name',   coalesce(g.name_kr, g.name_en, '(알 수 없는 게임)'),
    'game_image',  coalesce(g.image_url, ''),
    'review',      r.review,
    'rating',      r.rating,
    'updated_at',  coalesce(r.review_updated_at, r.updated_at)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  left join public.players pl on pl.player_id = r.player_id
  left join public.games   g  on g.game_id   = r.game_id
  where r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from public._hub_person_ids(p_hub_id))
    and exists (select 1 from public.hub_games hg
                 where hg.hub_id = p_hub_id and hg.game_id = r.game_id);
$$;
grant execute on function public.get_all_reviews(text) to anon;

-- ---- 3) 관리자 평점 탭: 지금 선반에 있는 게임의 평점만 ----
create or replace function public.get_all_ratings(p_player_id text, p_pin text default null)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  select * into v_auth from public.players where player_id = p_player_id;
  if v_auth is null or coalesce(v_auth.role, '') <> 'admin' then
    raise exception '관리자만 조회할 수 있습니다.';
  end if;
  return (
    select coalesce(json_agg(json_build_object(
      'game_id',     r.game_id,
      'game_name',   coalesce(g.name_kr, g.name_en, r.game_id),
      'game_image',  coalesce(g.image_url, ''),
      'player_name', coalesce(
        (select lp.name from public.players lp
          where lp.hub_id = v_auth.hub_id
            and (lp.player_id = r.player_id
                 or (pl.auth_uid is not null and lp.auth_uid = pl.auth_uid))
          order by lp.player_id limit 1), pl.name, r.player_id),
      'rating',      r.rating,
      'review',      r.review
    )), '[]'::json)
    from public.ratings r
    left join public.players pl on pl.player_id = r.player_id
    left join public.games   g  on g.game_id   = r.game_id
    where (r.rating is not null or (r.review is not null and btrim(r.review) <> ''))
      and r.player_id in (select player_id from public._hub_person_ids(v_auth.hub_id))
      and exists (select 1 from public.hub_games hg
                   where hg.hub_id = v_auth.hub_id and hg.game_id = r.game_id)
  );
end $$;
grant execute on function public.get_all_ratings(text, text) to anon;

-- ---- 4) 게임 팝업 후기(기록장/동료): 쓴 허브의 선반에 아직 있는 후기만 ----
create or replace function public.get_reviews_mates(p_game_id text)
returns json
language sql stable security definer
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
    select pl.player_id, max(pl.play_date) as last_date
    from public.playlogs pl
    join my_sess ms on ms.hub_id = pl.hub_id and ms.session_id = pl.session_id
    where coalesce(pl.player_id, '') <> ''
    group by pl.player_id
  ),
  mates as (
    select player_id from mates_raw
    union
    select p2.player_id
    from mates_raw mr
    join public.players p1 on p1.player_id = mr.player_id and p1.auth_uid is not null
    join public.players p2 on p2.auth_uid = p1.auth_uid
    union
    select player_id from my
  )
  select coalesce(json_agg(json_build_object(
    'name', coalesce(
      (select p2.name from public.players p2
        join mates_raw mr on mr.player_id = p2.player_id
        where p2.player_id = r.player_id
           or (p.auth_uid is not null and p2.auth_uid = p.auth_uid)
        order by mr.last_date desc nulls last limit 1),
      p.name),
    'review', r.review,
    'updated_at', coalesce(r.review_updated_at, r.updated_at),
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from mates)
    and (r.hub_id is null or exists (select 1 from public.hub_games hg
                                      where hg.hub_id = r.hub_id and hg.game_id = r.game_id));
$$;
revoke all on function public.get_reviews_mates(text) from anon, public;
grant execute on function public.get_reviews_mates(text) to authenticated;

-- ---- 5) 기록장 후기 탭(내 허브들 통합): 동일한 선반 기준 ----
create or replace function public.get_all_reviews_mates()
returns json
language sql stable security definer
set search_path = public
as $$
  with my_hubs as (
    select distinct hub_id from public.players where auth_uid = auth.uid()
  ),
  members as (
    select distinct h.player_id
    from my_hubs mh
    cross join lateral public._hub_person_ids(mh.hub_id) h
  )
  select coalesce(json_agg(json_build_object(
    'player_id',   r.player_id,
    'player_name', coalesce(
      (select lp.name from public.players lp
        join my_hubs mh on mh.hub_id = lp.hub_id
        where lp.player_id = r.player_id
           or (pl.auth_uid is not null and lp.auth_uid = pl.auth_uid)
        order by lp.hub_id, lp.player_id limit 1), pl.name, '익명'),
    'game_id',     r.game_id,
    'game_name',   coalesce(g.name_kr, g.name_en, '(알 수 없는 게임)'),
    'game_image',  coalesce(g.image_url, ''),
    'review',      r.review,
    'rating',      r.rating,
    'updated_at',  coalesce(r.review_updated_at, r.updated_at),
    'hub_name',    coalesce(h.name, r.hub_id)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  left join public.players pl on pl.player_id = r.player_id
  left join public.games   g  on g.game_id   = r.game_id
  left join public.hubs    h  on h.hub_id    = r.hub_id
  where r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from members)
    and (r.hub_id is null or exists (select 1 from public.hub_games hg
                                      where hg.hub_id = r.hub_id and hg.game_id = r.game_id));
$$;
revoke all on function public.get_all_reviews_mates() from anon, public;
grant execute on function public.get_all_reviews_mates() to authenticated;
