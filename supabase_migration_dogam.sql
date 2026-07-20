-- ============================================================
--  마이그레이션: 게임 도감 브라우즈 (catalog_browse)
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  전체 도감(공용 games)을 플레이 기록 많은 순으로 페이지 단위(50개씩)로
--  불러온다. 카테고리 필터 + 이름/영문/분류/요약 통합 검색(공백 무시) 지원.
--  play_count = 전 허브 합산 플레이 세션 수(글로벌 인기 순).
--  on_shelf = 현재 허브(p_hub_id) 서가에 이미 있는지 여부.
-- ============================================================

-- 이전(필터 없는) 시그니처가 있으면 제거(오버로드 충돌 방지)
drop function if exists public.catalog_browse(text, text, text, int, int);

create or replace function public.catalog_browse(
  p_hub_id   text,
  p_category text    default null,
  p_term     text    default null,
  p_players  int     default null,   -- 이 인원수를 지원하는 게임(min<=n<=max)
  p_wlo      numeric default null,    -- 난이도 하한
  p_whi      numeric default null,    -- 난이도 상한
  p_whi_inc  boolean default false,   -- 상한 포함 여부(마지막 구간만 true)
  p_limit    int     default 50,
  p_offset   int     default 0
) returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    json_agg(to_json(r) order by r.play_count desc, r.name_kr),
    '[]'::json
  )
  from (
    select
      g.game_id,
      g.name_kr,
      coalesce(g.name_en, '')   as name_en,
      coalesce(g.category, '')  as category,
      g.min_players,
      g.max_players,
      g.playtime_min,
      g.weight,
      coalesce(g.summary_kr, '') as summary_kr,
      coalesce(g.image_url, '')  as image_url,
      (hg.game_id is not null)   as on_shelf,
      coalesce(pc.play_count, 0) as play_count
    from public.games g
    left join public.hub_games hg
      on hg.game_id = g.game_id and hg.hub_id = p_hub_id
    left join (
      select game_id, count(distinct session_id) as play_count
      from public.playlogs
      group by game_id
    ) pc on pc.game_id = g.game_id
    where (coalesce(p_category, '') = '' or g.category = p_category)
      and (
        coalesce(btrim(p_term), '') = ''
        or regexp_replace(
             lower(coalesce(g.name_kr,'') || ' ' || coalesce(g.name_en,'') || ' '
                   || coalesce(g.category,'') || ' ' || coalesce(g.summary_kr,'')),
             '\s+', '', 'g')
           like '%' || regexp_replace(lower(btrim(p_term)), '\s+', '', 'g') || '%'
      )
      and (
        p_players is null
        or (coalesce(g.min_players, 1) <= p_players and coalesce(g.max_players, 99) >= p_players)
      )
      and (
        p_wlo is null
        or (g.weight is not null and g.weight >= p_wlo
            and (case when p_whi_inc then g.weight <= p_whi else g.weight < p_whi end))
      )
    order by play_count desc, g.name_kr
    limit  greatest(coalesce(p_limit, 50), 0)
    offset greatest(coalesce(p_offset, 0), 0)
  ) r;
$$;

grant execute on function public.catalog_browse(text, text, text, int, numeric, numeric, boolean, int, int) to anon;
