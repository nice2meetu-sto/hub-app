-- ============================================================
--  마이그레이션: 개인 기록장에 등록한 게임은 공용 도감에서 숨김
--  supabase_fix_all.sql / supabase_migration_dogam.sql 실행 후에 Run.
--  여러 번 실행해도 안전.
--
--  문제
--    · 도감(catalog_browse)은 공용 games 전체를 보여줘서, 개인 기록장에
--      등록한 게임(예: 보난자)이 다른 일반 허브(슈필)의 도감에도 뜬다.
--    · 게임 탭(get_games)은 허브 선반 기준이라 이미 정상 — 도감만 문제.
--
--  수정
--    · games.personal_owner: 개인 기록장에서 처음 등록한 게임이면 그 기록장
--      hub_id를 기록(공용 게임은 null).
--    · add_game: 개인 기록장에서 새 게임 등록 시 personal_owner 설정.
--      반대로 어떤 클럽(비개인) 허브 선반에 담기면 공용으로 승격(null).
--    · catalog_browse: personal_owner 가 있으면 그 기록장 도감에서만 노출.
--      → 개인 기록장 게임은 다른 허브 도감에 안 뜸(내 기록장 도감·게임탭엔 그대로).
-- ============================================================

alter table public.games add column if not exists personal_owner text;

-- 기존 데이터 백필: 지금 개인 기록장 선반에만 있고 어떤 클럽에도 없는 게임 → 개인 소유로 표시
update public.games g
   set personal_owner = (
     select hh.hub_id from public.hub_games hh
       join public.hubs hb on hb.hub_id = hh.hub_id
      where hh.game_id = g.game_id and coalesce(hb.kind,'hub') = 'personal'
      order by hh.hub_id limit 1)
 where g.personal_owner is null
   and exists (select 1 from public.hub_games hh join public.hubs hb on hb.hub_id = hh.hub_id
               where hh.game_id = g.game_id and coalesce(hb.kind,'hub') = 'personal')
   and not exists (select 1 from public.hub_games hh join public.hubs hb on hb.hub_id = hh.hub_id
                   where hh.game_id = g.game_id and coalesce(hb.kind,'hub') <> 'personal');

-- ---- add_game: 개인 기록장 게임 표시 + 클럽 담기면 공용 승격 ----
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
    -- 클럽(비개인) 허브가 담으면 공용 도감으로 승격
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
     or nullif(p_payload->>'playtime_min','') is null then
    raise exception '인원수와 플레이타임을 입력해주세요.'; end if;

  v_id := public._next_id('G', 3, 'games', 'game_id');
  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, playtime_min, weight,
    summary_kr, image_url, source, created_by, created_at, personal_owner)
  values(
    v_id, v_name, coalesce(p_payload->>'name_en',''), v_cat,
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
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

-- ---- catalog_browse: 개인 기록장 게임은 그 기록장 도감에서만 노출 ----
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
      -- 개인 기록장 전용 게임은 그 기록장 도감에서만 노출(공용 게임은 personal_owner null)
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
