-- ============================================================
--  마이그레이션: 베스트 인원 + 플레이타임 범위 (구 앱 이식)
--  supabase_fix_all.sql + supabase_migration_personalgame.sql 이후에 Run.
--  여러 번 실행해도 안전.
--
--  · games.best_players: 권장/베스트 인원 — "4" 또는 "4-5" 자유 텍스트
--  · games.min_playtime / max_playtime: 플레이타임 범위("30~60분" 표시).
--    기존 playtime_min(단일) 값은 max_playtime 으로 이관하고,
--    호환을 위해 playtime_min 컬럼·응답 키는 계속 유지(최대값과 동기화).
--  · get_games / add_game / update_game / search_catalog / catalog_browse /
--    get_my_games_all 이 새 필드를 저장·반환하도록 갱신
--    (personal_owner 등 기존 동작은 전부 보존).
-- ============================================================

-- ---- 1) 컬럼 추가 + 데이터 이관 ----
alter table public.games add column if not exists best_players text;
alter table public.games add column if not exists min_playtime numeric;
alter table public.games add column if not exists max_playtime numeric;
update public.games set max_playtime = playtime_min
 where max_playtime is null and playtime_min is not null;

-- ---- 2) get_games: 새 필드 포함 ----
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

-- ---- 3) add_game: 새 필드 저장(개인 기록장 personal_owner 동작 보존) ----
create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_id text; v_existing text;
        v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_name text := btrim(coalesce(p_payload->>'name_kr',''));
        v_key  text := regexp_replace(lower(btrim(coalesce(p_payload->>'name_kr',''))), '\s+', '', 'g');
        v_cat  text := coalesce(p_payload->>'category','');
        v_hcat text := btrim(coalesce(p_payload->>'hub_category',''));
        v_is_personal boolean;
        v_tmax numeric := coalesce(nullif(p_payload->>'max_playtime','')::numeric,
                                   nullif(p_payload->>'playtime_min','')::numeric);
begin
  v_auth := public._verify(p_player_id, p_pin);
  if v_name = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if v_hcat = '' then raise exception 'Hub 분류를 선택해주세요.'; end if;

  select coalesce(kind,'hub') = 'personal' into v_is_personal
    from public.hubs where hub_id = v_auth.hub_id;

  select game_id into v_existing from public.games
   where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g') = v_key
   limit 1;

  if v_existing is not null then
    if exists (select 1 from public.hub_games
               where hub_id = v_auth.hub_id and game_id = v_existing) then
      raise exception '이미 등록된 게임명입니다.'; end if;
    insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
    values (v_auth.hub_id, v_existing, v_hcat, p_player_id, v_now);
    if not v_is_personal then
      update public.games set personal_owner = null
       where game_id = v_existing and personal_owner is not null;
    end if;
    return json_build_object('game_id', v_existing, 'name_kr', v_name, 'source', 'catalog');
  end if;

  -- 새 게임(도감 신규 등록)
  if coalesce(p_payload->>'image_url','') = '' then
    raise exception '이미지 URL 또는 게임 사진 중 하나는 꼭 등록해주세요.'; end if;
  if nullif(p_payload->>'min_players','') is null
     or nullif(p_payload->>'max_players','') is null
     or v_tmax is null then
    raise exception '인원수와 플레이타임을 입력해주세요.'; end if;

  v_id := public._next_id('G', 3, 'games', 'game_id');
  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, best_players,
    playtime_min, min_playtime, max_playtime, weight,
    summary_kr, image_url, source, created_by, created_at, personal_owner)
  values(
    v_id, v_name, coalesce(p_payload->>'name_en',''), v_cat,
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'best_players',''),
    v_tmax,   -- 호환: playtime_min = 최대 플레이타임과 동기화
    nullif(p_payload->>'min_playtime','')::numeric,
    v_tmax,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now,
    case when v_is_personal then v_auth.hub_id else null end
  );
  insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
  values (v_auth.hub_id, v_id, v_hcat, p_player_id, v_now);
  return json_build_object('game_id', v_id, 'name_kr', v_name, 'source', 'manual');
end $$;
grant execute on function public.add_game(text, text, jsonb) to anon;

-- ---- 4) update_game: 새 필드 수정 지원(공용/허브 분류 규칙 보존) ----
create or replace function public.update_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_gid text; v_hub_cnt int; v_shared boolean;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(v_auth.role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;

  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.hub_games
                 where hub_id = v_auth.hub_id and game_id = v_gid) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

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
      -- 호환: playtime_min 은 최대 플레이타임(또는 레거시 키)과 동기화
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

-- ---- 5) search_catalog: 새 필드 포함(가져오기 팝업용) ----
create or replace function public.search_catalog(p_hub_id text, p_term text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', coalesce(g.name_en,''),
    'category', coalesce(g.category,''),
    'min_players', g.min_players, 'max_players', g.max_players,
    'best_players', g.best_players,
    'playtime_min', g.playtime_min, 'min_playtime', g.min_playtime, 'max_playtime', g.max_playtime,
    'weight', g.weight,
    'summary_kr', coalesce(g.summary_kr,''),
    'image_url', coalesce(g.image_url,''),
    'on_shelf', (hg.game_id is not null)
  ) order by g.name_kr), '[]'::json)
  from public.games g
  left join public.hub_games hg on hg.game_id = g.game_id and hg.hub_id = p_hub_id
  where regexp_replace(lower(coalesce(g.name_kr,'') || ' ' || coalesce(g.name_en,'')), '\s+', '', 'g')
        like '%' || regexp_replace(lower(btrim(coalesce(p_term,''))), '\s+', '', 'g') || '%'
    and btrim(coalesce(p_term,'')) <> '';
$$;
grant execute on function public.search_catalog(text, text) to anon;

-- ---- 6) catalog_browse: 새 필드 포함(개인 기록장 숨김 규칙 보존) ----
create or replace function public.catalog_browse(
  p_hub_id   text,
  p_category text    default null,
  p_term     text    default null,
  p_players  int     default null,
  p_wlo      numeric default null,
  p_whi      numeric default null,
  p_whi_inc  boolean default false,
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
      g.best_players,
      g.playtime_min,
      g.min_playtime,
      g.max_playtime,
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
      and (g.personal_owner is null or g.personal_owner = p_hub_id)
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

-- ---- 7) get_my_games_all: 새 필드 포함(기록장 게임 카드용) ----
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
  ),
  mates as (select player_id from public._my_mate_ids())
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
    'best_players', g.best_players,
    'playtime_min', g.playtime_min,
    'min_playtime', g.min_playtime,
    'max_playtime', g.max_playtime,
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
                   where r.game_id = a.game_id and r.rating is not null
                     and r.player_id in (select player_id from mates)),
    'all_rating_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id and r.rating is not null
                           and r.player_id in (select player_id from mates)),
    'all_review_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id
                           and r.review is not null and btrim(r.review) <> ''
                           and r.player_id in (select player_id from mates))
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;
revoke all on function public.get_my_games_all() from anon, public;
grant execute on function public.get_my_games_all() to authenticated;
