-- ============================================================
--  마이그레이션: 허브별 분류(카테고리) 복원 + 도감/허브 분류 이원화
--  supabase_migration_suggest.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · 분류를 다시 허브별 커스텀으로: categories(hub_id, name, sort_order)
--    - 기존 전역 분류는 모든 허브에 복제, 새 허브는 기본 8종으로 시작
--    - 추가/이름변경/삭제(+게임 재분류) RPC 복원 — 각 허브 관리자용
--  · 게임 분류는 두 가지를 함께 관리:
--    - 도감 분류(games.category): 공용 도감 공통(기본 8종) — 통합 관리 기준
--    - 허브 분류(hub_games.category): 허브 커스텀 — 게임탭 표시·필터 기준
--  · add_game: 도감/허브 분류 각각 저장, 새 게임은 이미지(URL/사진) 필수
--  · add_play: 허브에 등록된 게임만 기록 가능(도감 자동 등재 제거)
--  · update_game: 허브 분류는 항상 수정 가능, 도감 분류는 공용 정보로
--    취급(여러 허브 공유 게임이면 수정 요청으로)
-- ============================================================

-- 1~4) 스키마·데이터 전환은 딱 한 번만 (재실행 시 각 허브의 커스텀 분류 보호:
--      관리자가 지운 기본 분류가 재실행으로 되살아나지 않도록 플래그로 가드)
do $$
declare v_done boolean;
begin
  create table if not exists public._migration_flags(name text primary key);
  select exists (select 1 from public._migration_flags where name = 'hubcat') into v_done;
  if v_done then return; end if;

  -- 1) categories: 허브별 컬럼 복원 — 기존 전역 분류를 모든 허브에 복제
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='categories' and column_name='hub_id') then
    alter table public.categories add column hub_id text;
    alter table public.categories drop constraint if exists categories_pkey;
    insert into public.categories(hub_id, name, sort_order)
    select h.hub_id, c.name, c.sort_order
      from public.hubs h cross join public.categories c
     where c.hub_id is null;
    delete from public.categories where hub_id is null;
    alter table public.categories add primary key (hub_id, name);
  end if;

  -- 2) 기본 8종 시딩: 모든 허브에 (이미 있으면 무시)
  insert into public.categories(hub_id, name, sort_order)
  select h.hub_id, c.name, c.sort
    from public.hubs h,
         (values ('전략',1),('마피아',2),('파티게임',3),('트릭테이킹',4),
                 ('1대1 게임',5),('카드게임',6),('경매게임',7),('협력게임',8)) c(name, sort)
  on conflict (hub_id, name) do nothing;

  -- 3) 허브 분류 백필: 비어있는 hub_games.category 는 도감 분류로 시작
  update public.hub_games hg
     set category = coalesce(g.category, '')
    from public.games g
   where g.game_id = hg.game_id
     and coalesce(hg.category, '') = '';

  -- 4) 사용 중인데 목록에 없는 분류 보완(허브별)
  insert into public.categories(hub_id, name, sort_order)
  select distinct hg.hub_id, hg.category, 99
    from public.hub_games hg
   where coalesce(hg.category, '') <> ''
  on conflict (hub_id, name) do nothing;

  insert into public._migration_flags(name) values ('hubcat');
end $$;

-- 5) 분류 이름 변경 전파: 이제 그 허브의 선반(hub_games)으로
create or replace function public._cat_rename_propagate()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.name is distinct from old.name then
    update public.hub_games set category = new.name
     where hub_id = new.hub_id and category = old.name;
  end if;
  return new;
end $$;

drop trigger if exists cat_rename_propagate on public.categories;
create trigger cat_rename_propagate
  after update of name on public.categories
  for each row execute function public._cat_rename_propagate();

-- 6) 허브별 분류 조회 RPC
create or replace function public.get_categories(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object('name', name, 'sort_order', sort_order)
                  order by sort_order, name), '[]'::json)
  from public.categories where hub_id = p_hub_id;
$$;
grant execute on function public.get_categories(text) to anon;
grant execute on function public.get_categories(text) to authenticated;

-- 7) 분류 관리 RPC 복원 (허브 관리자 전용, 자기 허브만)
create or replace function public.admin_add_category(
  p_player_id text, p_pin text, p_name text, p_sort int default null)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_name text := btrim(coalesce(p_name, ''));
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(v_auth.role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;
  if v_name = '' then raise exception '분류 이름을 입력하세요.'; end if;
  insert into public.categories(hub_id, name, sort_order)
  values (v_auth.hub_id, v_name,
          coalesce(p_sort, (select coalesce(max(sort_order),0)+1
                              from public.categories where hub_id = v_auth.hub_id)))
  on conflict (hub_id, name) do update set sort_order = excluded.sort_order;
  return json_build_object('name', v_name);
end $$;

create or replace function public.admin_update_category(
  p_player_id text, p_pin text, p_old_name text, p_new_name text, p_sort int default null)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
        v_old text := btrim(coalesce(p_old_name,'')); v_new text := btrim(coalesce(p_new_name,''));
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(v_auth.role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;
  if v_old = '' or v_new = '' then raise exception '분류 이름을 입력하세요.'; end if;
  if not exists (select 1 from public.categories where hub_id = v_auth.hub_id and name = v_old) then
    raise exception '분류를 찾을 수 없습니다.'; end if;
  if v_new <> v_old and exists (select 1 from public.categories where hub_id = v_auth.hub_id and name = v_new) then
    raise exception '이미 있는 분류 이름입니다.'; end if;
  -- 이름 변경은 트리거가 이 허브 게임들의 분류까지 함께 바꿔줌
  update public.categories set name = v_new, sort_order = coalesce(p_sort, sort_order)
   where hub_id = v_auth.hub_id and name = v_old;
  return json_build_object('name', v_new, 'renamed_from', v_old);
end $$;

create or replace function public.admin_delete_category(
  p_player_id text, p_pin text, p_name text, p_move_to text default null)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_name text := btrim(coalesce(p_name,''));
        v_move text := btrim(coalesce(p_move_to,'')); v_cnt int;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(v_auth.role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;
  if not exists (select 1 from public.categories where hub_id = v_auth.hub_id and name = v_name) then
    raise exception '분류를 찾을 수 없습니다.'; end if;

  select count(*) into v_cnt from public.hub_games
   where hub_id = v_auth.hub_id and category = v_name;
  if v_cnt > 0 then
    if v_move = '' then
      raise exception '이 분류를 쓰는 게임이 %개 있어요. 옮길 분류를 먼저 정해주세요.', v_cnt;
    end if;
    if not exists (select 1 from public.categories where hub_id = v_auth.hub_id and name = v_move) then
      raise exception '옮길 분류("%")가 없습니다.', v_move; end if;
    update public.hub_games set category = v_move
     where hub_id = v_auth.hub_id and category = v_name;
  end if;

  delete from public.categories where hub_id = v_auth.hub_id and name = v_name;
  return json_build_object('deleted', v_name, 'moved', v_cnt, 'moved_to', nullif(v_move,''));
end $$;

grant execute on function public.admin_add_category(text, text, text, int)          to anon;
grant execute on function public.admin_add_category(text, text, text, int)          to authenticated;
grant execute on function public.admin_update_category(text, text, text, text, int) to anon;
grant execute on function public.admin_update_category(text, text, text, text, int) to authenticated;
grant execute on function public.admin_delete_category(text, text, text, text)      to anon;
grant execute on function public.admin_delete_category(text, text, text, text)      to authenticated;

-- 8) create_hub: 새 허브에 기본 8분류 시딩
create or replace function public.create_hub(p_name text, p_kind text default 'hub')
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); v_id text; v_code text; h public.hubs;
        v_name text := btrim(coalesce(p_name,''));
        v_kind text := case when p_kind = 'personal' then 'personal' else 'hub' end;
begin
  if v_uid is null then raise exception '허브 개설에는 이메일 로그인이 필요합니다.'; end if;
  if v_name = '' then raise exception '허브 이름을 입력하세요.'; end if;
  if length(v_name) > 30 then raise exception '허브 이름은 30자 이하로 입력하세요.'; end if;

  if v_kind = 'personal' then
    select * into h from public.hubs
     where owner_uid = v_uid and kind = 'personal'
     order by hub_id limit 1;
    if found then
      return json_build_object('hub_id', h.hub_id, 'name', h.name,
                               'invite_code', h.invite_code, 'existing', true);
    end if;
  end if;

  v_id := public._next_id('H', 3, 'hubs', 'hub_id');
  v_code := upper(substring(md5(random()::text) from 1 for 6));
  insert into public.hubs(hub_id, name, invite_code, owner_uid, created_at, kind)
  values (v_id, v_name, v_code, v_uid, to_char(now(), 'YYYY-MM-DD'), v_kind);

  insert into public.categories(hub_id, name, sort_order) values
    (v_id,'전략',1),(v_id,'마피아',2),(v_id,'파티게임',3),(v_id,'트릭테이킹',4),
    (v_id,'1대1 게임',5),(v_id,'카드게임',6),(v_id,'경매게임',7),(v_id,'협력게임',8)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code, 'existing', false);
end $$;

-- 9) get_games: 표시 분류 = 허브 분류(없으면 도감 분류), 도감 분류는 별도 필드로
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
    'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
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

-- 10) add_game: 도감/허브 분류 각각 저장, 새 게임은 이미지 필수
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
begin
  v_auth := public._verify(p_player_id, p_pin);
  if v_name = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if v_hcat = '' then raise exception 'Hub 분류를 선택해주세요.'; end if;

  select game_id into v_existing from public.games
   where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g') = v_key
   limit 1;

  if v_existing is not null then
    if exists (select 1 from public.hub_games
               where hub_id = v_auth.hub_id and game_id = v_existing) then
      raise exception '이미 등록된 게임명입니다.'; end if;
    insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
    values (v_auth.hub_id, v_existing, v_hcat, p_player_id, v_now);
    return json_build_object('game_id', v_existing, 'name_kr', v_name, 'source', 'catalog');
  end if;

  -- 새 게임(도감 신규 등록): 통합 관리자가 사진으로 확인할 수 있게 이미지 필수,
  -- 인원수·플레이타임도 필수(도감 데이터 품질 유지)
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
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id, v_name, coalesce(p_payload->>'name_en',''), v_cat,
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );
  insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
  values (v_auth.hub_id, v_id, v_hcat, p_player_id, v_now);
  return json_build_object('game_id', v_id, 'name_kr', v_name, 'source', 'manual');
end $$;

-- 11) add_play: 허브에 등록된 게임만 기록 가능(도감 자동 등재 제거)
create or replace function public.add_play(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_auth public.players;
  v_sid text; v_maxrec int; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
  v_date text; v_dur numeric; v_gid text; v_part jsonb; v_count int;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception '게임을 선택하세요.'; end if;
  if not exists (select 1 from public.hub_games
                 where hub_id = v_auth.hub_id and game_id = v_gid) then
    raise exception '허브에 등록된 게임만 기록할 수 있어요. [게임 추가]로 먼저 등록해주세요.'; end if;
  if jsonb_typeof(p_payload->'participants') <> 'array'
     or jsonb_array_length(p_payload->'participants') = 0 then
    raise exception '참가자가 없습니다.'; end if;

  v_sid := public._next_id('S', 4, 'playlogs', 'session_id');
  select coalesce(max((substring(record_id from '^R([0-9]+)$'))::int), 0)
    into v_maxrec from public.playlogs;
  v_date := coalesce(nullif(p_payload->>'play_date',''), to_char(now(),'YYYY-MM-DD'));
  v_dur  := nullif(p_payload->>'duration_min','')::numeric;

  for v_part in select * from jsonb_array_elements(p_payload->'participants') loop
    v_maxrec := v_maxrec + 1;
    insert into public.playlogs(
      record_id, session_id, hub_id, play_date, game_id, duration_min,
      player_id, player_name, score, is_win, created_by, created_at)
    values(
      'R' || lpad(v_maxrec::text, 5, '0'), v_sid, v_auth.hub_id, v_date, v_gid, v_dur,
      nullif(v_part->>'player_id',''),
      coalesce(v_part->>'player_name',''),
      nullif(v_part->>'score','')::numeric,
      coalesce((v_part->>'is_win')::boolean, false),
      p_player_id, v_now
    );
  end loop;

  v_count := jsonb_array_length(p_payload->'participants');
  return json_build_object('session_id', v_sid, 'count', v_count);
end $$;

-- 12) update_game: 허브 분류는 항상 수정 가능, 도감 분류는 공용 정보 취급
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
                         'playtime_min','weight','summary_kr','image_url']) then
    if v_shared then
      raise exception '여러 허브가 함께 쓰는 게임이라 공용 정보(도감 분류 포함)는 수정할 수 없습니다.';
    end if;
    update public.games set
      name_kr   = coalesce(p_payload->>'name_kr', name_kr),
      name_en   = coalesce(p_payload->>'name_en', name_en),
      category  = coalesce(p_payload->>'category', category),
      min_players  = case when p_payload ? 'min_players'  then nullif(p_payload->>'min_players','')::numeric  else min_players end,
      max_players  = case when p_payload ? 'max_players'  then nullif(p_payload->>'max_players','')::numeric  else max_players end,
      playtime_min = case when p_payload ? 'playtime_min' then nullif(p_payload->>'playtime_min','')::numeric else playtime_min end,
      weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
      summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
      image_url  = coalesce(p_payload->>'image_url', image_url)
    where game_id = v_gid;
  end if;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;

-- 13) search_catalog: 도감 검색 결과에 전체 정보 포함(가져오기 팝업용)
create or replace function public.search_catalog(p_hub_id text, p_term text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', coalesce(g.name_en,''),
    'category', coalesce(g.category,''),
    'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
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
