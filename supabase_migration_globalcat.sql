-- ============================================================
--  마이그레이션: 카테고리 전역(공통) 관리 전환 + 데이터 보수
--  supabase_migration_personal.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  결정 변경: 카테고리는 허브별 → 전역 공통 관리
--    · 분류 목록은 전체 서비스 공통 8종:
--      전략 / 마피아 / 파티게임 / 트릭테이킹 / 1대1 게임 / 카드게임 / 경매게임 / 협력게임
--    · 게임의 분류는 공용 도감(games.category)에 저장 — 도감에서 끌어오면
--      분류도 그대로 따라옴(연동)
--    · admin 분류 관리는 전역 목록을 수정(어느 허브 관리자든 가능)
--
--  보수: 마이그레이션 이전에 만든 개인 기록장의 kind 복구
-- ============================================================

-- 0) 데이터 보수: '…의 기록장' 이름의 허브를 personal로
update public.hubs set kind = 'personal'
 where coalesce(kind,'hub') = 'hub' and name like '%의 기록장';

-- 1) games.category 백필: 선반에 저장돼 있던 분류를 도감으로 승격
update public.games g
   set category = (
     select hg.category from public.hub_games hg
      where hg.game_id = g.game_id and coalesce(hg.category,'') <> ''
      order by hg.added_at nulls last limit 1)
 where coalesce(g.category,'') = ''
   and exists (select 1 from public.hub_games hg
                where hg.game_id = g.game_id and coalesce(hg.category,'') <> '');

-- 2) categories 전역화: (hub_id, name) → name 단일 키 + 기본 7종으로 재구성
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='categories' and column_name='hub_id') then
    alter table public.categories drop constraint if exists categories_pkey;
    delete from public.categories;
    alter table public.categories drop column hub_id;
    alter table public.categories add primary key (name);
  end if;
end $$;

insert into public.categories(name, sort_order) values
  ('전략',1),('마피아',2),('파티게임',3),('트릭테이킹',4),
  ('1대1 게임',5),('카드게임',6),('경매게임',7),('협력게임',8)
on conflict (name) do nothing;

-- 3) get_games: 분류를 도감(games.category)에서
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
    from public.ratings where hub_id = p_hub_id group by game_id
  ),
  pc as (
    select game_id, count(distinct session_id) as play_count
    from public.playlogs where hub_id = p_hub_id group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', coalesce(g.category, ''), 'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.hub_games hg
  join public.games g on g.game_id = hg.game_id
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id
  where hg.hub_id = p_hub_id;
$$;

-- 4) add_game: 분류를 도감에 저장(신규일 때). 도감에 이미 있으면 기존 분류 유지
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
begin
  v_auth := public._verify(p_player_id, p_pin);
  if v_name = '' then raise exception '한글 게임명을 입력하세요.'; end if;

  select game_id into v_existing from public.games
   where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g') = v_key
   limit 1;

  if v_existing is not null then
    if exists (select 1 from public.hub_games
               where hub_id = v_auth.hub_id and game_id = v_existing) then
      raise exception '이미 등록된 게임명입니다.'; end if;
    insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
    values (v_auth.hub_id, v_existing, '', p_player_id, v_now);
    return json_build_object('game_id', v_existing, 'name_kr', v_name, 'source', 'catalog');
  end if;

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
  values (v_auth.hub_id, v_id, '', p_player_id, v_now);
  return json_build_object('game_id', v_id, 'name_kr', v_name, 'source', 'manual');
end $$;

-- 5) update_game: 분류는 도감에 저장(공통이므로 공유 게임이어도 수정 가능),
--    나머지 공용 정보는 기존 규칙 유지(여러 허브 사용 시 차단)
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

  if p_payload ? 'category' then
    update public.games set category = coalesce(p_payload->>'category', category)
     where game_id = v_gid;
  end if;

  select count(distinct hub_id) into v_hub_cnt from public.hub_games where game_id = v_gid;
  v_shared := v_hub_cnt > 1;
  if (p_payload ?| array['name_kr','name_en','min_players','max_players',
                         'playtime_min','weight','summary_kr','image_url']) then
    if v_shared then
      raise exception '여러 허브가 함께 쓰는 게임이라 공용 정보는 수정할 수 없습니다. (분류는 수정 가능)';
    end if;
    update public.games set
      name_kr   = coalesce(p_payload->>'name_kr', name_kr),
      name_en   = coalesce(p_payload->>'name_en', name_en),
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

-- 6) 분류 관리 RPC: 전역 목록 대상
create or replace function public.admin_add_category(
  p_player_id text, p_pin text, p_name text, p_sort int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public._verify_admin(p_player_id, p_pin);
  if btrim(coalesce(p_name,'')) = '' then raise exception '분류 이름을 입력하세요.'; end if;
  insert into public.categories(name, sort_order) values (btrim(p_name), coalesce(p_sort, 0))
  on conflict (name) do update set sort_order = excluded.sort_order;
  return json_build_object('name', btrim(p_name), 'sort_order', coalesce(p_sort, 0));
end $$;

create or replace function public.admin_update_category(
  p_player_id text, p_pin text, p_old_name text, p_new_name text, p_sort int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_old text := btrim(coalesce(p_old_name,'')); v_new text := btrim(coalesce(p_new_name,''));
begin
  perform public._verify_admin(p_player_id, p_pin);
  if v_old = '' or v_new = '' then raise exception '분류 이름을 입력하세요.'; end if;
  if not exists (select 1 from public.categories where name = v_old) then
    raise exception '분류를 찾을 수 없습니다.'; end if;
  if v_new <> v_old and exists (select 1 from public.categories where name = v_new) then
    raise exception '이미 있는 분류 이름입니다.'; end if;

  update public.categories set name = v_new, sort_order = coalesce(p_sort, sort_order) where name = v_old;
  if v_new <> v_old then
    update public.games set category = v_new where category = v_old;
  end if;
  return json_build_object('name', v_new, 'renamed_from', v_old);
end $$;

-- 7) create_hub: 허브별 분류 시딩 제거(전역 목록 사용)
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

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code, 'existing', false);
end $$;
