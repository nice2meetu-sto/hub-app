-- ============================================================
--  마이그레이션: 도감 검색 띄어쓰기 무시
--  supabase_migration_hubrating.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  '매직 넘버' 로 검색해도 '매직넘버일레븐' 이 찾아지도록
--  검색어와 게임명 모두 공백 제거 후 비교 (add_game의 중복 판정과 동일 규칙)
-- ============================================================

create or replace function public.search_catalog(p_hub_id text, p_term text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'image_url', coalesce(g.image_url,''),
    'on_shelf', (hg.game_id is not null)
  ) order by g.name_kr), '[]'::json)
  from public.games g
  left join public.hub_games hg on hg.game_id = g.game_id and hg.hub_id = p_hub_id
  where regexp_replace(lower(coalesce(g.name_kr,'') || ' ' || coalesce(g.name_en,'')), '\s+', '', 'g')
        like '%' || regexp_replace(lower(btrim(coalesce(p_term,''))), '\s+', '', 'g') || '%'
    and btrim(coalesce(p_term,'')) <> '';
$$;
