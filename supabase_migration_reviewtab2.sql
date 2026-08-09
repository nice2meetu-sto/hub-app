-- ============================================================
--  마이그레이션: 기록장(개인 허브) 후기 탭 — 내 허브 동료들 후기 통합
--  supabase_migration_reviewtab.sql 이후에 Run. 여러 번 실행해도 안전.
--
--  기존 후기 탭은 get_all_reviews(현재 허브) = '그 허브 구성원' 기준이라
--  개인 기록장에서는 구성원이 나뿐 → 내 후기만 보였다.
--  get_all_reviews_mates(): 로그인 계정(auth.uid)이 속한 모든 허브의
--  구성원(연동 인물 포함) 후기를 최신순으로 반환 — 기록장 후기 탭용.
--  이름은 나와 같은 허브에서 쓰는 닉네임을 우선 표시.
-- ============================================================

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
    and r.player_id in (select player_id from members);
$$;
revoke all on function public.get_all_reviews_mates() from anon, public;
grant execute on function public.get_all_reviews_mates() to authenticated;
