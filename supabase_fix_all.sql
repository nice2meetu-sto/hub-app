-- ============================================================
--  ★ 한 번에 실행하는 합본 마이그레이션 ★
--  아직 적용되지 않았을 수 있는 마이그레이션을 순서대로 담았습니다.
--  (personal → globalcat → catlock → cattrigger → myall → personrating → hubrating → searchnorm → adminops → kst → trim → suggest → hubcat → idcap)
--  이미 적용된 부분이 있어도 여러 번 실행해도 안전합니다.
--  Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- ============================================================

-- ============================================================
--  마이그레이션: 개인 기록장 규칙 + 연결 계정 자동 로그인
--  supabase_migration_linked.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hubs.kind ('hub' | 'personal') 구분 추가
--  · create_hub: 개인 기록장은 계정당 1개 — 이미 있으면 새로 만들지 않고
--    기존 기록장을 반환(existing: true) → 앱이 그리로 재입장
--  · login_linked: 계정에 연결된 멤버로 PIN 없이 로그인(기기 변경/재입장용.
--    이메일 인증이 PIN보다 강한 증명이므로 안전)
-- ============================================================

alter table public.hubs add column if not exists kind text default 'hub';

drop function if exists public.create_hub(text);
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

  -- 개인 기록장은 계정당 1개: 이미 있으면 그 기록장을 반환
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
    (v_id,'전략',1),(v_id,'마피아',2),(v_id,'트릭테이킹',3),(v_id,'파티',4),(v_id,'협력',5),
    (v_id,'덱빌딩',6),(v_id,'추리',7),(v_id,'가족',8),(v_id,'아브스트랙트',9),(v_id,'기타',10)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code, 'existing', false);
end $$;
revoke all on function public.create_hub(text, text) from anon, public;
grant execute on function public.create_hub(text, text) to authenticated;

-- 연결된 멤버로 로그인(PIN 불요). 앱 쓰기 RPC용 pin도 함께 반환
-- (관리자 페이지가 이미 PIN을 노출하는 현 모델과 동일 수준의 접근)
create or replace function public.login_linked(p_hub_id text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); r public.players;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  select * into r from public.players
   where hub_id = p_hub_id and auth_uid = v_uid and coalesce(status,'active') <> 'left'
   order by player_id limit 1;
  if not found then raise exception '이 허브에 연결된 멤버가 없습니다.'; end if;
  return json_build_object('player_id', r.player_id, 'name', r.name,
                           'role', coalesce(r.role,'member'), 'hub_id', r.hub_id,
                           'pin', coalesce(r.pin, ''));
end $$;
revoke all on function public.login_linked(text) from anon, public;
grant execute on function public.login_linked(text) to authenticated;

-- my_hubs에 kind 포함(개인 기록장 구분 표시용)
create or replace function public.my_hubs()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
    'is_owner', (h.owner_uid = public._auth_uid())
  ) order by h.hub_id), '[]'::json)
  from public.hubs h
  where h.owner_uid = public._auth_uid()
     or exists (select 1 from public.hub_admins a
                where a.hub_id = h.hub_id and a.auth_uid = public._auth_uid());
$$;

-- 허브 정보/연결 목록/초대코드 조회에 kind 포함(개인 기록장 구분 표시·동작용)
create or replace function public.get_hub(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object('hub_id', hub_id, 'name', name, 'kind', coalesce(kind,'hub'))
  from public.hubs where hub_id = p_hub_id;
$$;

create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name, 'kind', coalesce(h.kind,'hub'),
    'player_id', p.player_id, 'name', p.name,
    'status', coalesce(p.status,'active')
  ) order by (coalesce(h.kind,'hub') = 'personal') desc, p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid();
$$;

create or replace function public.hub_by_invite(p_code text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare h public.hubs;
begin
  if btrim(coalesce(p_code,'')) = '' then
    raise exception '초대코드를 입력하세요.'; end if;
  select * into h from public.hubs
   where upper(invite_code) = upper(btrim(p_code));
  if not found then raise exception '초대코드가 올바르지 않습니다.'; end if;
  return json_build_object('hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'));
end $$;
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

-- 0) (제거됨) 이름 기반 kind 보수 — 기록장 판별은 kind 컬럼만 사용.
--    기록장은 create_hub(p_kind='personal')로만 만들어지며 계정당 1개 강제.
--    이름은 판별에 전혀 쓰이지 않으므로 자유롭게 변경 가능.

-- 1) games.category 백필: 선반에 저장돼 있던 분류를 도감으로 승격
update public.games g
   set category = (
     select hg.category from public.hub_games hg
      where hg.game_id = g.game_id and coalesce(hg.category,'') <> ''
      order by hg.added_at nulls last limit 1)
 where coalesce(g.category,'') = ''
   and exists (select 1 from public.hub_games hg
                where hg.game_id = g.game_id and coalesce(hg.category,'') <> '');

-- 2) categories 전역화: (hub_id, name) → name 단일 키 + 기본 8종으로 재구성
--    ※ 이후 hubcat 마이그레이션이 다시 허브별로 되돌림 — 이미 hubcat이
--      적용된 DB에서 재실행할 때는 이 블록을 건너뜀(커스텀 분류 보호)
do $$
declare v_hubcat boolean := false;
begin
  if to_regclass('public._migration_flags') is not null then
    select exists (select 1 from public._migration_flags where name = 'hubcat') into v_hubcat;
  end if;
  if v_hubcat then return; end if;

  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='categories' and column_name='hub_id') then
    alter table public.categories drop constraint if exists categories_pkey;
    delete from public.categories;
    alter table public.categories drop column hub_id;
    alter table public.categories add primary key (name);
  end if;

  insert into public.categories(name, sort_order) values
    ('전략',1),('마피아',2),('파티게임',3),('트릭테이킹',4),
    ('1대1 게임',5),('카드게임',6),('경매게임',7),('협력게임',8)
  on conflict (name) do nothing;
end $$;

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
-- (재실행 대비: 이후 hubcat이 기본값 있는 시그니처로 다시 만들므로 먼저 제거)
drop function if exists public.admin_add_category(text, text, text, int);
drop function if exists public.admin_update_category(text, text, text, text, int);
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
-- ============================================================
--  마이그레이션: 분류 관리를 운영자 전용으로 전환
--  supabase_migration_globalcat.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  분류(전역 7종)는 통합 관리자(운영자)가 SQL/대시보드에서 직접 관리.
--  허브 관리자용 분류 수정 RPC는 제거.
--
--  운영자 참고 — 분류 관리 SQL 예시:
--    · 추가:   insert into categories(name, sort_order) values ('신규분류', 8);
--    · 순서:   update categories set sort_order = 3 where name = '카드게임';
--    · 이름변경(게임 데이터까지 함께):
--        update categories set name = '새이름' where name = '옛이름';
--        update games set category = '새이름' where category = '옛이름';
-- ============================================================

drop function if exists public.admin_add_category(text, text, text, int);
drop function if exists public.admin_update_category(text, text, text, text, int);
-- ============================================================
--  마이그레이션: 분류 이름 변경 자동 전파 트리거
--  supabase_migration_catlock.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  운영자가 Table Editor에서 categories.name 을 직접 바꾸면
--  그 분류를 쓰는 games.category 도 자동으로 따라 변경됩니다.
--  → 분류 관리는 Table Editor 에서 자유롭게 (추가/순서/이름변경/삭제)
-- ============================================================

create or replace function public._cat_rename_propagate()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.name is distinct from old.name then
    update public.games set category = new.name where category = old.name;
  end if;
  return new;
end $$;

drop trigger if exists cat_rename_propagate on public.categories;
create trigger cat_rename_propagate
  after update of name on public.categories
  for each row execute function public._cat_rename_propagate();
-- ============================================================
--  마이그레이션: MY 플레이 기록·게임 기록 통합(전 허브)
--  supabase_fix_all.sql(또는 personal 마이그레이션) 실행 후에 Run.
--  여러 번 실행해도 안전.
--
--  · get_my_plays_all: 내 계정에 연결된 전 허브에서 내가 참가한
--    플레이 세션 목록 (get_plays와 동일 형태 + hub_id/hub_name)
--  · get_my_games_all: 허브×게임별 내 플레이 집계 + 내 평점
--    (앱이 범위(전체/허브별)에 맞게 합산해 게임 기록 탭에 표시)
-- ============================================================

create or replace function public.get_my_plays_all()
returns json
language sql stable security definer
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  msess as (   -- 내가 참가한 세션 (허브 포함)
    select distinct p.hub_id, p.session_id
    from public.playlogs p
    join my on my.player_id = p.player_id and my.hub_id = p.hub_id
  ),
  parts as (
    select p.hub_id, p.session_id, p.record_id,
      json_build_object(
        'record_id', p.record_id,
        'player_id', p.player_id,
        'name', coalesce(nullif(btrim(p.player_name), ''), pl.name, p.player_id),
        'is_guest', (p.player_id is null or p.player_id = '' or pl.player_id is null),
        'score', p.score,
        'is_win', coalesce(p.is_win, false)
      ) as participant
    from public.playlogs p
    join msess ms on ms.hub_id = p.hub_id and ms.session_id = p.session_id
    left join public.players pl on pl.player_id = p.player_id
  ),
  sess as (
    select s.hub_id, s.session_id, s.play_date, s.game_id, s.duration_min, s.created_by,
           g.name_kr, g.name_en, g.image_url, h.name as hub_name
    from (
      select distinct on (hub_id, session_id)
             hub_id, session_id, play_date, game_id, duration_min, created_by
      from public.playlogs p
      where exists (select 1 from msess ms
                    where ms.hub_id = p.hub_id and ms.session_id = p.session_id)
      order by hub_id, session_id, record_id
    ) s
    left join public.games g on g.game_id = s.game_id
    left join public.hubs h on h.hub_id = s.hub_id
  )
  select coalesce(json_agg(json_build_object(
    'session_id',   se.session_id,
    'hub_id',       se.hub_id,
    'hub_name',     coalesce(se.hub_name, se.hub_id),
    'play_date',    se.play_date,
    'game_id',      se.game_id,
    'game_name',    coalesce(se.name_kr, se.name_en, '(알 수 없는 게임)'),
    'game_image',   coalesce(se.image_url, ''),
    'duration_min', se.duration_min,
    'created_by',   coalesce(se.created_by, ''),
    'participants', (
      select coalesce(json_agg(pa.participant order by pa.record_id), '[]'::json)
      from parts pa where pa.hub_id = se.hub_id and pa.session_id = se.session_id
    )
  ) order by se.play_date desc, se.session_id desc), '[]'::json)
  from sess se;
$$;

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
  )
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
    'playtime_min', g.playtime_min,
    'weight',       g.weight,
    'summary_kr',   coalesce(g.summary_kr, ''),
    'plays',     a.plays,
    'wins',      a.wins,
    'first_rn',  a.first_rn,
    'my_rating', (select r.rating from public.ratings r
                  join my m on m.player_id = r.player_id
                  where r.game_id = a.game_id and r.hub_id = a.hub_id
                    and r.rating is not null
                  limit 1),
    -- 전체 평점/후기: 공용 도감 기준, 모든 허브 이용자 집계
    'all_rating', (select round(avg(r.rating)::numeric, 1) from public.ratings r
                   where r.game_id = a.game_id and r.rating is not null),
    'all_rating_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id and r.rating is not null),
    'all_review_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id
                           and r.review is not null and btrim(r.review) <> '')
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;

-- 게임의 전체 후기(모든 허브) — 공용 도감 기준 모아보기용.
-- get_reviews(허브 범위)와 동일 형태 + hub_name
create or replace function public.get_reviews_all(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at,
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> '';
$$;

-- 안전장치: 한 계정은 한 허브에 멤버 1명만 연결 가능(중복 연결 금지)
create or replace function public.link_player(p_hub_id text, p_player_id text, p_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := public._auth_uid(); r public.players; v_is_admin boolean;
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  r := public._verify(p_player_id, p_pin);
  if r.hub_id <> p_hub_id then raise exception '이 허브의 멤버가 아닙니다.'; end if;
  if r.auth_uid is not null and r.auth_uid is distinct from v_uid then
    raise exception '이미 다른 계정에 연결된 멤버입니다.'; end if;
  if exists (select 1 from public.players
             where hub_id = p_hub_id and auth_uid = v_uid
               and player_id <> p_player_id) then
    raise exception '이미 연결된 허브예요.'; end if;

  v_is_admin := exists (select 1 from public.hubs
                        where hub_id = p_hub_id and owner_uid = v_uid)
             or exists (select 1 from public.hub_admins
                        where hub_id = p_hub_id and auth_uid = v_uid);

  update public.players
     set auth_uid = v_uid,
         role = case when v_is_admin then 'admin' else role end
   where player_id = p_player_id;

  return json_build_object('player_id', p_player_id, 'hub_id', p_hub_id,
                           'linked', true, 'role_admin', v_is_admin);
end $$;

-- get_my_links에 초대코드·PIN 포함
-- (초대코드: 허브 전환 메뉴 복사용 / PIN: 기록장 관리자탭 셀프 관리용 —
--  login_linked가 이미 본인에게 pin을 돌려주는 것과 동일 수준의 접근)
create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name, 'kind', coalesce(h.kind,'hub'),
    'invite', coalesce(h.invite_code, ''),
    'player_id', p.player_id, 'name', p.name, 'pin', coalesce(p.pin, ''),
    'status', coalesce(p.status,'active')
  ) order by (coalesce(h.kind,'hub') = 'personal') desc, p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid();
$$;

-- 내 멤버 정보 셀프 수정: 계정에 연결된 허브의 내 닉네임·비밀번호 변경
create or replace function public.update_my_member(p_hub_id text, p_name text, p_pin text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); r public.players;
        v_name text := btrim(coalesce(p_name, ''));
begin
  if v_uid is null then raise exception '이메일 로그인이 필요합니다.'; end if;
  select * into r from public.players
   where hub_id = p_hub_id and auth_uid = v_uid
     and coalesce(status,'active') <> 'left'
   order by player_id limit 1;
  if not found then raise exception '이 허브에 연결된 멤버가 없습니다.'; end if;

  if v_name <> '' and lower(v_name) <> lower(btrim(r.name)) then
    if exists (select 1 from public.players
               where hub_id = p_hub_id and lower(btrim(name)) = lower(v_name)
                 and player_id <> r.player_id) then
      raise exception '이미 사용 중인 닉네임입니다.'; end if;
    update public.players set name = v_name where player_id = r.player_id;
    -- 플레이 기록의 이름 스냅샷도 함께 갱신(기록 표시가 새 닉네임을 따르도록)
    update public.playlogs set player_name = v_name
     where player_id = r.player_id and coalesce(btrim(player_name), '') <> '';
  end if;

  if coalesce(p_pin, '') <> '' then
    if p_pin !~ '^\d{4}$' then raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;
    update public.players set pin = p_pin where player_id = r.player_id;
  end if;

  return json_build_object('player_id', r.player_id, 'hub_id', p_hub_id,
                           'name', case when v_name <> '' then v_name else r.name end);
end $$;

revoke all on function public.update_my_member(text, text, text) from anon, public;
grant execute on function public.update_my_member(text, text, text) to authenticated;

revoke all on function public.get_my_plays_all() from anon, public;
revoke all on function public.get_my_games_all() from anon, public;
grant execute on function public.get_my_plays_all() to authenticated;
grant execute on function public.get_my_games_all() to authenticated;
grant execute on function public.get_reviews_all(text) to anon;
grant execute on function public.get_reviews_all(text) to authenticated;
-- ============================================================
--  마이그레이션: 평점·후기·메모를 '사람×게임' 기준으로 통합
--  supabase_migration_myall.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · 게임은 공용 도감이므로 평점/후기/메모도 허브와 무관하게
--    (게임, 사람) 단위로 하나만 존재
--  · '사람' = 같은 이메일 계정(auth_uid)에 연결된 멤버들은 한 사람.
--    연결 없는 멤버는 player_id 그대로가 한 사람
--  · 읽기: 게임 평점 = 전체 이용자 평균, 후기 = 전체 후기
--  · 쓰기: 같은 사람의 기존 행이 있으면 그 행을 갱신(중복 생성 방지)
-- ============================================================

-- 0) 같은 사람(계정)의 형제 멤버들이 남긴 중복 행 병합
--    (최근 행을 남기고, 비어있는 필드는 다른 행에서 채운 뒤 삭제)
do $$
declare rec record; keep text;
begin
  for rec in
    select p.auth_uid, r.game_id,
           array_agg(r.player_id order by r.updated_at desc nulls last) as pids
    from public.ratings r
    join public.players p on p.player_id = r.player_id
    where p.auth_uid is not null
    group by p.auth_uid, r.game_id
    having count(*) > 1
  loop
    keep := rec.pids[1];
    update public.ratings k set
      rating = coalesce(k.rating,
        (select r2.rating from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and r2.rating is not null
          order by r2.updated_at desc nulls last limit 1)),
      review = coalesce(nullif(btrim(coalesce(k.review,'')),''),
        (select r2.review from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and coalesce(btrim(r2.review),'') <> ''
          order by r2.updated_at desc nulls last limit 1)),
      memo = coalesce(nullif(btrim(coalesce(k.memo,'')),''),
        (select r2.memo from public.ratings r2
          where r2.game_id = rec.game_id and r2.player_id = any(rec.pids)
            and coalesce(btrim(r2.memo),'') <> ''
          order by r2.updated_at desc nulls last limit 1))
    where k.game_id = rec.game_id and k.player_id = keep;
    delete from public.ratings
     where game_id = rec.game_id and player_id = any(rec.pids) and player_id <> keep;
  end loop;
end $$;

-- 1) 같은 사람의 기존 평점 행 주인 찾기(없으면 본인)
create or replace function public._rating_owner(p_player_id text, p_game_id text)
returns text
language sql stable
set search_path = public
as $$
  select coalesce(
    (select r.player_id from public.ratings r
      where r.game_id = p_game_id
        and r.player_id in (
          select p2.player_id from public.players p1
          join public.players p2 on p2.auth_uid = p1.auth_uid
          where p1.player_id = p_player_id and p1.auth_uid is not null)
      order by r.updated_at desc nulls last limit 1),
    p_player_id);
$$;

-- 2) 쓰기: 사람 단위 한 행에 저장
create or replace function public.save_rating(
  p_player_id text, p_pin text, p_game_id text, p_rating numeric)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if p_rating is null or p_rating < 1 or p_rating > 10 then
    raise exception '평점은 1~10 사이여야 합니다.'; end if;
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, rating, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, p_rating, v_now)
  on conflict (player_id, game_id) do update
    set rating = excluded.rating, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'rating', p_rating, 'updated_at', v_now);
end $$;

create or replace function public.save_review(
  p_player_id text, p_pin text, p_game_id text, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, review, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, coalesce(p_review, ''), v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;

create or replace function public.save_memo(
  p_player_id text, p_pin text, p_game_id text, p_memo text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
        v_auth public.players; v_owner text;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_owner := public._rating_owner(p_player_id, p_game_id);
  insert into public.ratings(player_id, game_id, hub_id, memo, updated_at)
  values (v_owner, p_game_id, v_auth.hub_id, coalesce(p_memo, ''), v_now)
  on conflict (player_id, game_id) do update
    set memo = excluded.memo, updated_at = excluded.updated_at;
  return json_build_object('player_id', v_owner, 'game_id', p_game_id, 'memo', coalesce(p_memo, ''));
end $$;

-- 3) 읽기: 게임 평점/후기 = 전체 이용자 기준 (허브 필터 제거)
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
    from public.ratings group by game_id
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

-- get_reviews: 전체 후기(허브 인자는 호환용으로 무시, 허브명 포함)
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select public.get_reviews_all(p_game_id);
$$;

-- get_my_ratings: 같은 사람(계정 형제 멤버)의 행까지 포함해 반환
create or replace function public.get_my_ratings(p_player_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id',    r.game_id,
    'game',       coalesce(g.name_kr, g.name_en, r.game_id),
    'rating',     r.rating,
    'memo',       coalesce(r.memo, ''),
    'review',     coalesce(r.review, ''),
    'updated_at', r.updated_at
  )), '[]'::json)
  from public.ratings r
  left join public.games g on g.game_id = r.game_id
  where r.player_id = p_player_id
     or r.player_id in (
       select p2.player_id from public.players p1
       join public.players p2 on p2.auth_uid = p1.auth_uid
       where p1.player_id = p_player_id and p1.auth_uid is not null);
$$;

-- 4) get_my_games_all: 내 평점을 허브와 무관하게(사람 기준) 조회
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
  )
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
    'playtime_min', g.playtime_min,
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
                   where r.game_id = a.game_id and r.rating is not null),
    'all_rating_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id and r.rating is not null),
    'all_review_count', (select count(*) from public.ratings r
                         where r.game_id = a.game_id
                           and r.review is not null and btrim(r.review) <> '')
  ) order by a.first_rn), '[]'::json)
  from agg a
  left join public.games g on g.game_id = a.game_id
  left join public.hubs h on h.hub_id = a.hub_id;
$$;
-- ============================================================
--  마이그레이션: 평점·후기 표시 범위 정리
--  supabase_migration_personrating.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  저장은 사람×게임 1개(personrating) 그대로. 보이는 범위만 정리:
--  · 허브 게임탭: 우리 허브 가입자('사람' 기준)의 평점·후기만 —
--    가입자가 다른 허브에서 남긴 것도 그 사람 것이므로 포함
--  · 기록장: 나와 같은 세션에서 게임한 사람들(+나)의 평점·후기만
-- ============================================================

-- 허브 가입자를 '사람' 단위로 확장한 player_id 목록
-- (가입자의 계정에 연결된 다른 허브 멤버 id 포함 — 평점 행 주인이
--  어느 허브 멤버로 저장돼 있어도 그 사람이면 잡히도록)
create or replace function public._hub_person_ids(p_hub_id text)
returns table(player_id text)
language sql stable
set search_path = public
as $$
  select p.player_id from public.players p where p.hub_id = p_hub_id
  union
  select p2.player_id
  from public.players p1
  join public.players p2 on p2.auth_uid = p1.auth_uid
  where p1.hub_id = p_hub_id and p1.auth_uid is not null;
$$;

-- 게임탭: ★ = 우리 허브 가입자 기준 평점/후기 수
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

-- 후기: 우리 허브 가입자의 후기만.
-- 닉네임은 '보는 허브'의 멤버 닉네임으로 표시(다른 허브에서 남겼어도
-- 그 사람의 이 허브 닉네임으로 보임) + 남긴 곳 허브명 포함
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', coalesce(
      (select lp.name from public.players lp
        where lp.hub_id = p_hub_id
          and (lp.player_id = r.player_id
               or (p.auth_uid is not null and lp.auth_uid = p.auth_uid))
        order by lp.player_id limit 1), p.name),
    'review', r.review, 'updated_at', r.updated_at,
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from public._hub_person_ids(p_hub_id));
$$;

-- 나와 같은 세션에서 게임한 사람들(+나)을 '사람' 단위로 확장한 id 목록
create or replace function public._my_mate_ids()
returns table(player_id text)
language sql stable
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  my_sess as (
    select distinct pl.hub_id, pl.session_id
    from public.playlogs pl
    join my on my.player_id = pl.player_id and my.hub_id = pl.hub_id
  ),
  mates_raw as (
    select distinct pl.player_id
    from public.playlogs pl
    join my_sess ms on ms.hub_id = pl.hub_id and ms.session_id = pl.session_id
    where coalesce(pl.player_id, '') <> ''
  )
  select player_id from mates_raw
  union
  select p2.player_id
  from mates_raw mr
  join public.players p1 on p1.player_id = mr.player_id and p1.auth_uid is not null
  join public.players p2 on p2.auth_uid = p1.auth_uid
  union
  select player_id from my;
$$;

-- 기록장 후기 보기: 나와 게임한 사람들의 후기만.
-- 이름은 '내가 같이 플레이한 기록에 나온 닉네임'으로 표시(내가 아는 이름).
-- 여러 허브에서 같이 했다면 가장 최근에 함께한 판의 닉네임 사용
create or replace function public.get_reviews_mates(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  with my as (
    select player_id, hub_id from public.players where auth_uid = auth.uid()
  ),
  my_sess as (
    select distinct pl.hub_id, pl.session_id
    from public.playlogs pl
    join my on my.player_id = pl.player_id and my.hub_id = pl.hub_id
  ),
  mates_raw as (
    select pl.player_id, max(pl.play_date) as last_date
    from public.playlogs pl
    join my_sess ms on ms.hub_id = pl.hub_id and ms.session_id = pl.session_id
    where coalesce(pl.player_id, '') <> ''
    group by pl.player_id
  ),
  mates as (
    select player_id from mates_raw
    union
    select p2.player_id
    from mates_raw mr
    join public.players p1 on p1.player_id = mr.player_id and p1.auth_uid is not null
    join public.players p2 on p2.auth_uid = p1.auth_uid
    union
    select player_id from my
  )
  select coalesce(json_agg(json_build_object(
    'name', coalesce(
      (select p2.name from public.players p2
        join mates_raw mr on mr.player_id = p2.player_id
        where p2.player_id = r.player_id
           or (p.auth_uid is not null and p2.auth_uid = p.auth_uid)
        order by mr.last_date desc nulls last limit 1),
      p.name),
    'review', r.review, 'updated_at', r.updated_at,
    'hub_name', coalesce(h.name, r.hub_id)
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  left join public.hubs h on h.hub_id = r.hub_id
  where r.game_id = p_game_id
    and r.review is not null and btrim(r.review) <> ''
    and r.player_id in (select player_id from mates);
$$;
revoke all on function public.get_reviews_mates(text) from anon, public;
grant execute on function public.get_reviews_mates(text) to authenticated;

-- 기록장 게임 카드: all_rating 계열 = 나와 게임한 사람들 기준
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
    'playtime_min', g.playtime_min,
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
-- ============================================================
--  마이그레이션: 관리자 넘기기(2-3) + 허브 탈퇴 처리(2-5)
--  supabase_migration_searchnorm.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hub_transfer_owner_to_player: 가입자 목록에서 멤버를 지정해
--    관리자 이전(대상은 이메일 연결 멤버). 이전 관리자는 공동 관리자로 잔류
--  · admin_set_left: 관리자가 멤버를 소프트 탈퇴(status='left') / 복귀 처리
--    — 기록·통계 보존, 멤버 목록·자동완성·로그인에서만 제외
--  · admin_get_players: 탈퇴 멤버도 status와 함께 반환(복귀 처리용)
-- ============================================================

-- 관리자 이전(멤버 지정): 현 소유자 로그인 상태에서만. 대상의 role도 admin으로
create or replace function public.hub_transfer_owner_to_player(p_hub_id text, p_player_id text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_new uuid;
begin
  select auth_uid into v_new from public.players
   where player_id = p_player_id and hub_id = p_hub_id;
  if not found then raise exception '이 허브의 멤버가 아닙니다.'; end if;
  if v_new is null then
    raise exception '대상 멤버가 이메일 계정에 연결되어 있어야 합니다.'; end if;
  perform public.hub_transfer_owner(p_hub_id, v_new);   -- 소유자 검증 포함
  update public.players set role = 'admin' where player_id = p_player_id;
  return json_build_object('hub_id', p_hub_id, 'player_id', p_player_id, 'transferred', true);
end $$;
revoke all on function public.hub_transfer_owner_to_player(text, text) from anon, public;
grant execute on function public.hub_transfer_owner_to_player(text, text) to authenticated;

-- 멤버 탈퇴/복귀 처리(관리자 전용, 소프트 탈퇴)
create or replace function public.admin_set_left(
  p_player_id text, p_pin text, p_target_id text, p_left boolean)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; t public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  select * into t from public.players
   where player_id = p_target_id and hub_id = v_auth.hub_id;
  if not found then raise exception '멤버를 찾을 수 없습니다.'; end if;
  if p_left and t.player_id = v_auth.player_id then
    raise exception '자기 자신은 탈퇴 처리할 수 없습니다.'; end if;
  if p_left and t.auth_uid is not null
     and exists (select 1 from public.hubs
                 where hub_id = v_auth.hub_id and owner_uid = t.auth_uid) then
    raise exception '허브 개설 계정의 멤버는 탈퇴 처리할 수 없습니다. (관리자 넘기기 후 가능)'; end if;

  update public.players
     set status = case when p_left then 'left' else 'active' end
   where player_id = p_target_id;
  return json_build_object('player_id', p_target_id,
                           'status', case when p_left then 'left' else 'active' end);
end $$;
grant execute on function public.admin_set_left(text, text, text, boolean) to anon;
grant execute on function public.admin_set_left(text, text, text, boolean) to authenticated;

-- 가입자 목록: 탈퇴 멤버 포함 + status (활동 멤버 먼저)
create or replace function public.admin_get_players(p_player_id text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  return (select coalesce(json_agg(json_build_object(
    'player_id', player_id, 'name', name, 'pin', coalesce(pin, ''),
    'role', coalesce(role, 'member'), 'joined_at', coalesce(joined_at, ''),
    'status', coalesce(status, 'active')
  ) order by (coalesce(status,'active') = 'left'), player_id), '[]'::json)
  from public.players
  where hub_id = v_auth.hub_id);
end $$;
-- ============================================================
--  마이그레이션: 기록 시간 한국 시간(KST) 통일
--  언제 실행해도 안전. 여러 번 실행해도 안전.
--
--  모든 쓰기 RPC가 to_char(now(), ...) 로 시간을 기록하는데,
--  now()의 표시 시간대가 DB 기본(UTC)이라 9시간 이른 시각으로
--  저장되고 있었음. DB 시간대를 Asia/Seoul로 바꾸면 함수 수정 없이
--  모든 기록 시각·날짜(가입일·플레이 생성·평점 수정 등)와
--  월별 통계(date_trunc)가 KST 기준이 된다.
--  ※ 새 연결부터 적용 — 실행 후 몇 분 내 자동 반영
-- ============================================================

do $$ begin
  execute format('alter database %I set timezone to %L', current_database(), 'Asia/Seoul');
end $$;

set timezone = 'Asia/Seoul';   -- 현재 세션에도 즉시 적용

-- (선택) 이미 UTC로 저장된 기존 시각을 KST로 보정하고 싶으면 아래 주석을
-- 풀어 한 번만 실행하세요. 날짜만 저장된 값(YYYY-MM-DD)은 건드리지 않습니다.
-- update public.ratings  set updated_at = to_char(updated_at::timestamp + interval '9 hours', 'YYYY-MM-DD HH24:MI:SS') where length(updated_at) > 10;
-- update public.playlogs set created_at = to_char(created_at::timestamp + interval '9 hours', 'YYYY-MM-DD HH24:MI:SS') where length(created_at) > 10;
-- update public.games    set created_at = to_char(created_at::timestamp + interval '9 hours', 'YYYY-MM-DD HH24:MI:SS') where length(created_at) > 10;
-- ============================================================
--  마이그레이션: playlogs 공백·줄바꿈 자동 정리(트리거)
--  언제 실행해도 안전. 여러 번 실행해도 안전.
--
--  Table Editor에서 수동 수정 시 엔터·공백이 섞여 들어가면
--  ('P016\n' ≠ 'P016') 그 기록이 화면에서 조용히 사라지는 문제 방지.
--  저장 시점에 핵심 컬럼의 앞뒤 공백·줄바꿈을 잘라낸다.
-- ============================================================

-- 기존 데이터 정리
update public.playlogs set
  player_id   = nullif(btrim(coalesce(player_id,''), E' \t\r\n'), ''),
  hub_id      = btrim(hub_id, E' \t\r\n'),
  session_id  = btrim(session_id, E' \t\r\n'),
  game_id     = btrim(coalesce(game_id,''), E' \t\r\n'),
  player_name = btrim(coalesce(player_name,''), E' \t\r\n')
where coalesce(player_id,'')   <> coalesce(nullif(btrim(coalesce(player_id,''), E' \t\r\n'), ''), '')
   or hub_id                   <> btrim(hub_id, E' \t\r\n')
   or session_id               <> btrim(session_id, E' \t\r\n')
   or coalesce(game_id,'')     <> btrim(coalesce(game_id,''), E' \t\r\n')
   or coalesce(player_name,'') <> btrim(coalesce(player_name,''), E' \t\r\n');

create or replace function public._trim_playlog()
returns trigger
language plpgsql
as $$
begin
  new.player_id   := nullif(btrim(coalesce(new.player_id,''), E' \t\r\n'), '');
  new.hub_id      := btrim(new.hub_id, E' \t\r\n');
  new.session_id  := btrim(new.session_id, E' \t\r\n');
  new.game_id     := btrim(coalesce(new.game_id,''), E' \t\r\n');
  new.player_name := btrim(coalesce(new.player_name,''), E' \t\r\n');
  return new;
end $$;

drop trigger if exists trim_playlog on public.playlogs;
create trigger trim_playlog
  before insert or update on public.playlogs
  for each row execute function public._trim_playlog();
-- ============================================================
--  마이그레이션: 건의 게시판(게임 정보 수정 요청) + 게임 공유 여부 표시
--  supabase_migration_hubrating.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · suggestions 테이블: 공용 도감 게임(여러 허브 공유)은 관리자가 직접
--    수정할 수 없으므로, 수정 요청을 남기는 건의 게시판.
--    게임 id · 요청자 id · 수정 내용 · 처리완료(status) 칼럼 포함
--  · add_suggestion RPC: 관리자가 [수정 요청]으로 남김
--  · get_games에 'shared'(여러 허브 공유 여부) 필드 추가 —
--    앱이 수정 화면에서 공용 정보를 잠글지 판단하는 근거
-- ============================================================

-- 1) 건의 게시판 테이블
create table if not exists public.suggestions (
  id          bigint generated always as identity primary key,
  game_id     text not null,             -- 대상 게임
  player_id   text not null,             -- 요청자(멤버 id)
  hub_id      text,                      -- 요청자가 속한 허브
  content     text not null,             -- 수정 내용(요청 본문)
  status      text not null default 'open',   -- 'open' | 'done' (처리완료 표시)
  created_at  text,
  resolved_at text                       -- 처리완료로 바꾼 시각(운영자가 기록)
);

alter table public.suggestions enable row level security;
-- 쓰기는 RPC(security definer)로만 — 직접 접근 정책은 만들지 않음

-- 2) 수정 요청 남기기 (관리자 PIN 확인 후)
create or replace function public.add_suggestion(
  p_player_id text, p_pin text, p_game_id text, p_content text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_content text := btrim(coalesce(p_content, ''));
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(v_auth.role,'') <> 'admin' then raise exception '관리자만 요청할 수 있습니다.'; end if;
  if v_content = '' then raise exception '수정 내용을 입력하세요.'; end if;
  if not exists (select 1 from public.games where game_id = p_game_id) then
    raise exception '게임을 찾을 수 없습니다.'; end if;
  insert into public.suggestions(game_id, player_id, hub_id, content, status, created_at)
  values (p_game_id, p_player_id, v_auth.hub_id, v_content, 'open',
          to_char(now(), 'YYYY-MM-DD HH24:MI:SS'));
  return json_build_object('ok', true);
end $$;

grant execute on function public.add_suggestion(text, text, text, text) to anon;
grant execute on function public.add_suggestion(text, text, text, text) to authenticated;

-- 3) get_games: shared(여러 허브가 함께 쓰는 게임) 여부 추가
--    (hubrating 버전 + shared 필드 — 나머지는 동일)
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
    'category', coalesce(g.category, ''), 'min_players', g.min_players, 'max_players', g.max_players,
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
    'added_at', coalesce(hg.added_at, ''),
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
      -- 기록번호: 5자리를 넘어가면 잘라내지 않고 자릿수 확장(R99999 → R100000)
      'R' || case when length(v_maxrec::text) >= 5 then v_maxrec::text
                  else lpad(v_maxrec::text, 5, '0') end,
      v_sid, v_auth.hub_id, v_date, v_gid, v_dur,
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
-- ============================================================
--  마이그레이션: ID 999(9999) 초과 시 자연 확장 — 잘림·충돌 방지
--  supabase_migration_hubcat.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  Postgres lpad는 지정 자릿수보다 길면 오른쪽을 잘라버림:
--    lpad('1000', 3, '0') → '100'  ⇒  P999 다음이 P100 (기존 ID와 충돌!)
--  자릿수(pad)는 '모자랄 때만' 채우고, 넘어가면 그대로 늘어나게 수정.
--    P999 → P1000 → …  (ID 컬럼은 text라 길이 제한 없음, 별도 조치 불필요)
-- ============================================================

-- 1) 공통 ID 생성기: H/P/G(3자리), S(4자리) 모두 여기서 처리
create or replace function public._next_id(p_prefix text, p_pad int, p_table text, p_col text)
returns text
language plpgsql stable security definer
set search_path = public
as $$
declare v_max int; v_txt text;
begin
  execute format(
    'select coalesce(max((substring(%I from %L))::int), 0) from public.%I',
    p_col, '^' || p_prefix || '([0-9]+)$', p_table
  ) into v_max;
  v_txt := (v_max + 1)::text;
  if length(v_txt) < p_pad then v_txt := lpad(v_txt, p_pad, '0'); end if;
  return p_prefix || v_txt;
end $$;
