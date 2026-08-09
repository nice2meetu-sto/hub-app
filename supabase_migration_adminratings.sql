-- ============================================================
--  마이그레이션: 관리자용 게임별 회원 평점 조회 (구 앱 이식, 멀티허브)
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  관리자만: 우리 허브 사람들의 게임별 평점 + 후기 내용 전체 반환.
--  구 앱과 달리 PIN 검증(_verify_admin)을 거치고, 허브 범위로 제한하며,
--  작성자 이름은 그 허브 닉네임으로 표시한다.
-- ============================================================

create or replace function public.get_all_ratings(p_player_id text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);   -- 관리자 확인(실패 시 예외)
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
