-- ============================================================
--  마이그레이션: 후기 탭(모두의 게임 후기) + 후기 시간 분리
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--  (구 앱 supabase_migration_allreviews/reviewtime 을 멀티허브에 맞게 이식)
--
--  · ratings.review_updated_at: 후기 전용 시간 — 별점·메모만 고쳐도
--    후기가 최신으로 올라오지 않게 분리. save_review에서만 갱신.
--  · get_all_reviews(p_hub_id): 그 허브 사람들 후기를 최신순으로
--    (작성자 허브 닉네임 + 게임명·이미지 포함) — 후기 탭 채팅 UI용.
--  · get_reviews / get_reviews_mates: 후기 시간을 review_updated_at
--    우선으로 반환(키 이름은 updated_at 그대로 → 프론트 수정 불필요).
-- ============================================================

-- ---- 컬럼 추가 + 기존 후기 백필 ----
alter table public.ratings add column if not exists review_updated_at text;
update public.ratings
   set review_updated_at = updated_at
 where review_updated_at is null
   and review is not null and btrim(review) <> '';

-- ---- save_review: 후기 내용이 실제로 바뀔 때만 후기 시간 갱신 ----
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
  insert into public.ratings(player_id, game_id, hub_id, review, review_updated_at, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, coalesce(p_review, ''), v_now, v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review,
        review_updated_at = case when public.ratings.review is distinct from excluded.review
                                 then excluded.review_updated_at
                                 else public.ratings.review_updated_at end,
        updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;
grant execute on function public.save_review(text, text, text, text) to anon;

-- ---- get_reviews: 후기 시간 = review_updated_at(없으면 updated_at) ----
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', coalesce(
      (select lp.name from public.players lp
        where lp.hub_id = p_hub_id
          and (lp.player_id = r.player_id
               or (p.auth_uid is not null and lp.auth_uid = p.auth_uid))
        order by lp.player_id limit 1), p.name),
    'review', r.review,
    'updated_at', coalesce(r.review_updated_at, r.updated_at),
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from public._hub_person_ids(p_hub_id));
$$;

-- ---- get_reviews_mates: 동일하게 후기 시간 기준 ----
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
    and r.player_id in (select player_id from mates);
$$;
revoke all on function public.get_reviews_mates(text) from anon, public;
grant execute on function public.get_reviews_mates(text) to authenticated;

-- ---- get_all_reviews: 후기 탭(채팅 UI) — 허브 범위 전체 후기 최신순 ----
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
    and r.player_id in (select player_id from public._hub_person_ids(p_hub_id));
$$;
grant execute on function public.get_all_reviews(text) to anon;
