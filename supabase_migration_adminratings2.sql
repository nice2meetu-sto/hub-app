-- ============================================================
--  마이그레이션: 관리자 평점 조회에서 PIN 검증 제거
--  supabase_migration_adminratings.sql 이후에 Run. 여러 번 실행해도 안전.
--
--  평점 탭에 들어갈 때마다 PIN을 묻지 않도록, PIN 검증(_verify_admin) 대신
--  호출자가 이 허브의 관리자(role='admin')인지만 확인한다.
--  (민감 정보 아님 — 후기는 이미 후기 탭에서 전원 공개)
-- ============================================================

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
  );
end $$;
grant execute on function public.get_all_ratings(text, text) to anon;
