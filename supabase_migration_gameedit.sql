-- ============================================================
--  마이그레이션: 등록자 본인 게임 수정 (구 앱 이식, 멀티허브 규칙)
--  supabase_migration_bestplaytime.sql 이후에 Run. 여러 번 실행해도 안전.
--
--  규칙(합의): 등록자 본인은 '다른 허브가 끌어다 쓰기 전까지'만 수정 가능.
--   · 우리 허브만 쓰는 게임: 관리자 + 등록자 본인('사람' 단위, _same_person)
--   · 여러 허브가 쓰는 게임: 공용 정보는 아무도 직접 수정 불가(기존 그대로,
--     수정 요청으로) — Hub 분류만 관리자/등록자가 바로 수정
--
--  · get_games: created_by 포함 → 프론트가 '내가 등록한 게임' 판별해
--    게임 카드에 ✏️ 수정 버튼 노출
--  · update_game: 권한을 '관리자만' → '관리자 또는 등록자 본인'으로
-- ============================================================

-- ---- get_games: created_by 포함(bestplaytime 버전 기반) ----
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
    from public.ratings
    where player_id in (select player_id from public._hub_person_ids(p_hub_id))
    group by game_id
  ),
  pc as (
    select game_id, count(distinct session_id) as play_count
    from public.playlogs where hub_id = p_hub_id group by game_id
  ),
  sh as (
    select game_id, count(distinct hub_id) as hub_cnt
    from public.hub_games group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', coalesce(nullif(hg.category,''), g.category, ''),
    'catalog_category', coalesce(g.category, ''),
    'added_at', coalesce(hg.added_at, ''),
    'min_players', g.min_players, 'max_players', g.max_players,
    'best_players', g.best_players,
    'playtime_min', g.playtime_min, 'min_playtime', g.min_playtime, 'max_playtime', g.max_playtime,
    'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'created_by', coalesce(g.created_by, ''),
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0),
    'shared', coalesce(sh.hub_cnt, 1) > 1
  ) order by g.game_id), '[]'::json)
  from public.hub_games hg
  join public.games g on g.game_id = hg.game_id
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id
  left join sh on sh.game_id = g.game_id
  where hg.hub_id = p_hub_id;
$$;

-- ---- update_game: 관리자 또는 등록자 본인(사람 단위) ----
create or replace function public.update_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_gid text; v_hub_cnt int; v_shared boolean;
        v_created text; v_can boolean;
begin
  v_auth := public._verify(p_player_id, p_pin);

  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.hub_games
                 where hub_id = v_auth.hub_id and game_id = v_gid) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

  select created_by into v_created from public.games where game_id = v_gid;
  v_can := coalesce(v_auth.role,'') = 'admin'
        or (coalesce(v_created,'') <> '' and public._same_person(p_player_id, v_created));
  if not v_can then
    raise exception '본인이 등록한 게임 또는 관리자만 수정할 수 있습니다.'; end if;

  -- 허브 분류: 우리 허브 선반에만 적용 — 항상 수정 가능
  if p_payload ? 'hub_category' then
    update public.hub_games set category = coalesce(p_payload->>'hub_category', category)
     where hub_id = v_auth.hub_id and game_id = v_gid;
  end if;

  select count(distinct hub_id) into v_hub_cnt from public.hub_games where game_id = v_gid;
  v_shared := v_hub_cnt > 1;
  if (p_payload ?| array['name_kr','name_en','category','min_players','max_players',
                         'best_players','playtime_min','min_playtime','max_playtime',
                         'weight','summary_kr','image_url']) then
    if v_shared then
      raise exception '여러 허브가 함께 쓰는 게임이라 공용 정보(도감 분류 포함)는 수정할 수 없습니다.';
    end if;
    update public.games set
      name_kr   = coalesce(p_payload->>'name_kr', name_kr),
      name_en   = coalesce(p_payload->>'name_en', name_en),
      category  = coalesce(p_payload->>'category', category),
      min_players  = case when p_payload ? 'min_players'  then nullif(p_payload->>'min_players','')::numeric  else min_players end,
      max_players  = case when p_payload ? 'max_players'  then nullif(p_payload->>'max_players','')::numeric  else max_players end,
      best_players = case when p_payload ? 'best_players' then nullif(p_payload->>'best_players','') else best_players end,
      min_playtime = case when p_payload ? 'min_playtime' then nullif(p_payload->>'min_playtime','')::numeric else min_playtime end,
      max_playtime = case when p_payload ? 'max_playtime' then nullif(p_payload->>'max_playtime','')::numeric else max_playtime end,
      playtime_min = case when p_payload ? 'max_playtime' then nullif(p_payload->>'max_playtime','')::numeric
                          when p_payload ? 'playtime_min' then nullif(p_payload->>'playtime_min','')::numeric
                          else playtime_min end,
      weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
      summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
      image_url  = coalesce(p_payload->>'image_url', image_url)
    where game_id = v_gid;
  end if;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;
grant execute on function public.update_game(text, text, jsonb) to anon;
