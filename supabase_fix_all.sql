-- ============================================================
--  ★ 한 번에 실행하는 합본 마이그레이션 ★
--  아직 적용되지 않았을 수 있는 4개 마이그레이션을 순서대로 담았습니다.
--  (personal → globalcat → catlock → cattrigger)
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
