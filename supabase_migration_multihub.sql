-- ============================================================
--  마이그레이션: 단일 허브 → 멀티허브 (ROADMAP 2-2 + 2-1 기반)
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전(멱등).
--
--  변경 요약
--    · hubs / hub_admins / hub_games 테이블 신설
--    · players: hub_id, auth_uid, status, PIN 잠금 컬럼 추가
--      닉네임 유일성: 전체 → 허브 단위 (hub_id, lower(name))
--    · playlogs / ratings / categories: hub_id 추가 (기존 데이터는 H001 귀속)
--    · games: 공용 도감으로 유지(hub_id 없음), 카테고리는 hub_games(선반)로 이동
--    · 모든 RPC를 허브 범위로 수정 — 단, p_hub_id default 'H001' 로
--      기존 앱(허브 개념 없는 호출)이 그대로 동작하는 하위호환 유지
--    · add_game: 도감에 있으면 "선반에만 추가"(끌어오기), 없으면 도감 생성+선반 추가
--
--  주의: PIN 시도 잠금은 컬럼·검사만 준비(2-1 본 구현은 앱 개편과 함께.
--        예외를 던지면 카운터 증가가 롤백되는 문제로 반환값 방식 전환 필요)
-- ============================================================

-- ============================================================
--  1) 새 테이블
-- ============================================================
create table if not exists public.hubs (
  hub_id      text primary key,
  name        text not null,
  invite_code text not null unique,
  owner_uid   uuid,                    -- 허브 관리자 Auth 계정(2-1에서 연결)
  created_at  text
);

create table if not exists public.hub_admins (   -- 공동 관리자(2-3)
  hub_id   text not null,
  auth_uid uuid not null,
  role     text not null default 'admin',
  primary key (hub_id, auth_uid)
);

-- 기본 허브: 기존 데이터가 전부 귀속될 곳
insert into public.hubs(hub_id, name, invite_code, created_at)
values ('H001', '우리 허브', upper(substring(md5(random()::text) from 1 for 6)),
        to_char(now(), 'YYYY-MM-DD'))
on conflict (hub_id) do nothing;

-- 허브 선반: 이 허브의 게임탭에 보이는 게임 + 허브별 카테고리
create table if not exists public.hub_games (
  hub_id   text not null,
  game_id  text not null,
  category text default '',
  added_by text,
  added_at text,
  primary key (hub_id, game_id)
);

-- ============================================================
--  2) 기존 테이블 컬럼 추가 + 백필
-- ============================================================
alter table public.players add column if not exists hub_id           text;
alter table public.players add column if not exists auth_uid         uuid;
alter table public.players add column if not exists status           text default 'active';
alter table public.players add column if not exists pin_failed       int  default 0;
alter table public.players add column if not exists pin_locked_until timestamptz;
update public.players set hub_id = 'H001' where hub_id is null;
alter table public.players alter column hub_id set not null;

alter table public.playlogs add column if not exists hub_id text;
update public.playlogs set hub_id = 'H001' where hub_id is null;

alter table public.ratings add column if not exists hub_id text;
update public.ratings set hub_id = 'H001' where hub_id is null;

alter table public.categories add column if not exists hub_id text;
update public.categories set hub_id = 'H001' where hub_id is null;

-- categories PK: name → (hub_id, name)
do $$ begin
  if exists (select 1 from information_schema.table_constraints
             where table_schema='public' and table_name='categories'
               and constraint_name='categories_pkey'
               and constraint_type='PRIMARY KEY') then
    if not exists (
      select 1 from information_schema.key_column_usage
      where table_schema='public' and table_name='categories'
        and constraint_name='categories_pkey' and column_name='hub_id') then
      alter table public.categories drop constraint categories_pkey;
      alter table public.categories add primary key (hub_id, name);
    end if;
  end if;
end $$;

-- 닉네임 유일성: 전체 → 허브 단위
alter table public.players drop constraint if exists players_name_key;
create unique index if not exists players_hub_name
  on public.players (hub_id, lower(btrim(name)));

-- 게임 카테고리를 허브 선반으로 이동(기존 게임 전부 H001 선반에)
insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
select 'H001', game_id, coalesce(category, ''), created_by, created_at
from public.games
on conflict (hub_id, game_id) do nothing;
-- games.category 는 레거시로 남김(더 이상 사용하지 않음)

create index if not exists idx_playlogs_hub  on public.playlogs(hub_id);
create index if not exists idx_ratings_hub   on public.ratings(hub_id);
create index if not exists idx_players_hub   on public.players(hub_id);
create index if not exists idx_hub_games_game on public.hub_games(game_id);

-- ============================================================
--  3) 내부 헬퍼
-- ============================================================

-- PIN 검증 v2: 탈퇴 회원 거부 + 잠금 시각 검사(잠금 부여는 2-1에서)
create or replace function public._verify(p_player_id text, p_pin text)
returns public.players
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  select * into r from public.players where player_id = p_player_id;
  if not found then raise exception '사용자를 찾을 수 없습니다.'; end if;
  if coalesce(r.status, 'active') = 'left' then
    raise exception '탈퇴한 회원입니다.'; end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then
    raise exception 'PIN 입력이 잠시 잠겼습니다. 잠시 후 다시 시도하세요.'; end if;
  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then raise exception 'PIN이 올바르지 않습니다.'; end if;
  return r;
end $$;
revoke all on function public._verify(text, text) from anon, public;

-- ============================================================
--  4) 인증 RPC (허브 범위)
-- ============================================================

-- 로그인: 허브 + 이름 + PIN (p_hub_id 생략 시 H001 = 기존 앱 하위호환)
drop function if exists public.login(text, text);
create or replace function public.login(p_name text, p_pin text, p_hub_id text default 'H001')
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  if coalesce(p_name,'') = '' or coalesce(p_pin,'') = '' then
    raise exception '이름과 PIN을 입력하세요.'; end if;
  select * into r from public.players
   where hub_id = p_hub_id and lower(btrim(name)) = lower(btrim(p_name));
  if not found then raise exception '사용자를 찾을 수 없습니다.'; end if;
  if coalesce(r.status, 'active') = 'left' then
    raise exception '탈퇴한 회원입니다.'; end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then
    raise exception 'PIN 입력이 잠시 잠겼습니다. 잠시 후 다시 시도하세요.'; end if;
  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then raise exception 'PIN이 올바르지 않습니다.'; end if;
  return json_build_object('player_id', r.player_id, 'name', r.name,
                           'role', coalesce(r.role,'member'), 'hub_id', r.hub_id);
end $$;

-- 가입: 허브 + 초대코드. H001은 코드 생략 허용(기존 앱 하위호환),
-- 다른 허브는 초대코드 필수. 허브 첫 가입자는 그 허브의 admin.
drop function if exists public.signup(text, text);
create or replace function public.signup(
  p_name text, p_pin text, p_hub_id text default 'H001', p_invite text default null)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_name text := btrim(p_name); v_pin text := btrim(p_pin);
        v_id text; v_role text; v_cnt int; v_hub public.hubs;
begin
  if v_name = '' then raise exception '닉네임을 입력하세요.'; end if;
  if length(v_name) > 20 then raise exception '닉네임은 20자 이하로 입력하세요.'; end if;
  if v_pin !~ '^\d{4}$' then raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;

  select * into v_hub from public.hubs where hub_id = p_hub_id;
  if not found then raise exception '허브를 찾을 수 없습니다.'; end if;
  if p_hub_id <> 'H001' or p_invite is not null then
    if upper(btrim(coalesce(p_invite,''))) <> upper(v_hub.invite_code) then
      raise exception '초대코드가 올바르지 않습니다.'; end if;
  end if;

  if exists (select 1 from public.players
             where hub_id = p_hub_id and lower(btrim(name)) = lower(v_name)) then
    raise exception '이미 사용 중인 닉네임입니다.'; end if;

  select count(*) into v_cnt from public.players where hub_id = p_hub_id;
  v_role := case when v_cnt = 0 then 'admin' else 'member' end;
  v_id := public._next_id('P', 3, 'players', 'player_id');

  insert into public.players(player_id, hub_id, name, pin, role, joined_at)
  values (v_id, p_hub_id, v_name, v_pin, v_role, to_char(now(), 'YYYY-MM-DD'));

  return json_build_object('player_id', v_id, 'name', v_name, 'role', v_role, 'hub_id', p_hub_id);
end $$;

-- 허브 기본 정보(초대코드 제외 — 코드는 노출 금지)
create or replace function public.get_hub(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object('hub_id', hub_id, 'name', name)
  from public.hubs where hub_id = p_hub_id;
$$;

-- ============================================================
--  5) 조회 RPC (허브 범위)
-- ============================================================

-- 게임 목록 = 이 허브 선반에 있는 게임(카테고리는 선반 값) + 이 허브의 평점/플레이 집계
drop function if exists public.get_games();
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
    'category', coalesce(hg.category, ''), 'min_players', g.min_players, 'max_players', g.max_players,
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

-- 공용 도감 검색(게임 추가 자동완성용): 이름 부분일치, 선반 등재 여부 포함
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
  where lower(coalesce(g.name_kr,'') || ' ' || coalesce(g.name_en,''))
        like '%' || lower(btrim(coalesce(p_term,''))) || '%'
    and btrim(coalesce(p_term,'')) <> '';
$$;

-- 플레이 목록: 이 허브 기록만
drop function if exists public.get_plays();
create or replace function public.get_plays(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  with parts as (
    select p.session_id, p.record_id,
      json_build_object(
        'record_id', p.record_id,
        'player_id', p.player_id,
        'name', coalesce(nullif(btrim(p.player_name), ''), pl.name, p.player_id),
        'is_guest', (p.player_id is null or p.player_id = '' or pl.player_id is null),
        'score', p.score,
        'is_win', coalesce(p.is_win, false)
      ) as participant
    from public.playlogs p
    left join public.players pl on pl.player_id = p.player_id
    where p.hub_id = p_hub_id
  ),
  sess as (
    select s.session_id, s.play_date, s.game_id, s.duration_min, s.created_by,
           g.name_kr, g.name_en, g.image_url
    from (
      select distinct on (session_id)
             session_id, play_date, game_id, duration_min, created_by
      from public.playlogs
      where hub_id = p_hub_id
      order by session_id, record_id
    ) s
    left join public.games g on g.game_id = s.game_id
  )
  select coalesce(json_agg(json_build_object(
    'session_id',   se.session_id,
    'play_date',    se.play_date,
    'game_id',      se.game_id,
    'game_name',    coalesce(se.name_kr, se.name_en, '(알 수 없는 게임)'),
    'game_image',   coalesce(se.image_url, ''),
    'duration_min', se.duration_min,
    'created_by',   coalesce(se.created_by, ''),
    'participants', (
      select coalesce(json_agg(pa.participant order by pa.record_id), '[]'::json)
      from parts pa where pa.session_id = se.session_id
    )
  ) order by se.play_date desc, se.session_id desc), '[]'::json)
  from sess se;
$$;

-- 게임별 공개 후기: 이 허브 것만
drop function if exists public.get_reviews(text);
create or replace function public.get_reviews(p_game_id text, p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  where r.game_id = p_game_id and r.hub_id = p_hub_id
    and r.review is not null and btrim(r.review) <> '';
$$;

-- get_player_stats / get_my_ratings: player_id가 허브에 귀속되므로 변경 불필요

-- ============================================================
--  6) 쓰기 RPC (허브 범위 — 허브는 항상 "작성자 소속 허브"로 결정)
-- ============================================================

-- 평점/후기/메모: ratings 에 작성자 허브 기록
create or replace function public.save_rating(
  p_player_id text, p_pin text, p_game_id text, p_rating numeric)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS'); v_auth public.players;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if p_rating is null or p_rating < 1 or p_rating > 10 then
    raise exception '평점은 1~10 사이여야 합니다.'; end if;
  insert into public.ratings(player_id, game_id, hub_id, rating, updated_at)
  values (p_player_id, p_game_id, v_auth.hub_id, p_rating, v_now)
  on conflict (player_id, game_id) do update
    set rating = excluded.rating, hub_id = excluded.hub_id, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'rating', p_rating, 'updated_at', v_now);
end $$;

create or replace function public.save_review(
  p_player_id text, p_pin text, p_game_id text, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS'); v_auth public.players;
begin
  v_auth := public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, hub_id, review, updated_at)
  values (p_player_id, p_game_id, v_auth.hub_id, coalesce(p_review, ''), v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review, hub_id = excluded.hub_id, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;

create or replace function public.save_memo(
  p_player_id text, p_pin text, p_game_id text, p_memo text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS'); v_auth public.players;
begin
  v_auth := public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, hub_id, memo, updated_at)
  values (p_player_id, p_game_id, v_auth.hub_id, coalesce(p_memo, ''), v_now)
  on conflict (player_id, game_id) do update
    set memo = excluded.memo, hub_id = excluded.hub_id, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'memo', coalesce(p_memo, ''));
end $$;

-- 플레이 추가: 작성자 허브로 기록 + 그 게임을 허브 선반에 자동 등재
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

  -- 플레이한 게임은 허브 선반에 자동 등재(이미 있으면 무시)
  insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
  values (v_auth.hub_id, v_gid, '', p_player_id, v_now)
  on conflict (hub_id, game_id) do nothing;

  v_count := jsonb_array_length(p_payload->'participants');
  return json_build_object('session_id', v_sid, 'count', v_count);
end $$;

-- update_play / delete_play: 세션 단위 권한 검사 그대로 (허브 무관 로직) — 변경 없음

-- 게임 추가 v2: 공용 도감 검사 → 있으면 선반에만 추가(끌어오기), 없으면 도감 생성+선반 추가
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

  -- 공용 도감에서 동일 이름(띄어쓰기·대소문자 무시) 검색
  select game_id into v_existing from public.games
   where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g') = v_key
   limit 1;

  if v_existing is not null then
    -- 이미 우리 선반에 있으면 중복
    if exists (select 1 from public.hub_games
               where hub_id = v_auth.hub_id and game_id = v_existing) then
      raise exception '이미 등록된 게임명입니다.'; end if;
    -- 도감의 게임을 우리 선반으로 끌어오기
    insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
    values (v_auth.hub_id, v_existing, v_cat, p_player_id, v_now);
    return json_build_object('game_id', v_existing, 'name_kr', v_name, 'source', 'catalog');
  end if;

  -- 도감에 없음 → 새로 생성 + 선반 추가
  v_id := public._next_id('G', 3, 'games', 'game_id');
  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, playtime_min, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id, v_name, coalesce(p_payload->>'name_en',''), '',
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );
  insert into public.hub_games(hub_id, game_id, category, added_by, added_at)
  values (v_auth.hub_id, v_id, v_cat, p_player_id, v_now);
  return json_build_object('game_id', v_id, 'name_kr', v_name, 'source', 'manual');
end $$;

-- 게임 수정 v2(관리자): 카테고리는 자기 허브 선반에, 공용 정보는
-- "그 게임을 쓰는 허브가 우리뿐일 때만" 수정 허용(여럿이면 운영자 문의)
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

  -- 카테고리: 우리 허브 선반 값만 변경
  if p_payload ? 'category' then
    update public.hub_games set category = coalesce(p_payload->>'category', category)
     where hub_id = v_auth.hub_id and game_id = v_gid;
  end if;

  -- 공용 정보: 이 게임을 선반에 올린 허브가 우리뿐일 때만
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

-- ============================================================
--  7) 관리자 RPC (자기 허브 범위로 제한)
-- ============================================================

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
    'role', coalesce(role, 'member'), 'joined_at', coalesce(joined_at, '')
  ) order by player_id), '[]'::json)
  from public.players
  where hub_id = v_auth.hub_id and coalesce(status,'active') <> 'left');
end $$;

create or replace function public.admin_update_pin(
  p_player_id text, p_pin text, p_target_id text, p_new_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  if btrim(coalesce(p_new_pin,'')) !~ '^\d{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;
  update public.players
     set pin = btrim(p_new_pin), pin_failed = 0, pin_locked_until = null
   where player_id = p_target_id and hub_id = v_auth.hub_id;
  if not found then raise exception '회원을 찾을 수 없습니다.'; end if;
  return json_build_object('player_id', p_target_id, 'updated', true);
end $$;

create or replace function public.admin_add_category(
  p_player_id text, p_pin text, p_name text, p_sort int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  if btrim(coalesce(p_name,'')) = '' then raise exception '분류 이름을 입력하세요.'; end if;
  insert into public.categories(hub_id, name, sort_order)
  values (v_auth.hub_id, btrim(p_name), coalesce(p_sort, 0))
  on conflict (hub_id, name) do update set sort_order = excluded.sort_order;
  return json_build_object('name', btrim(p_name), 'sort_order', coalesce(p_sort, 0));
end $$;

create or replace function public.admin_update_category(
  p_player_id text, p_pin text, p_old_name text, p_new_name text, p_sort int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players;
        v_old text := btrim(coalesce(p_old_name,'')); v_new text := btrim(coalesce(p_new_name,''));
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  if v_old = '' or v_new = '' then raise exception '분류 이름을 입력하세요.'; end if;
  if not exists (select 1 from public.categories
                 where hub_id = v_auth.hub_id and name = v_old) then
    raise exception '분류를 찾을 수 없습니다.'; end if;
  if v_new <> v_old and exists (select 1 from public.categories
                                where hub_id = v_auth.hub_id and name = v_new) then
    raise exception '이미 있는 분류 이름입니다.'; end if;

  update public.categories set name = v_new, sort_order = coalesce(p_sort, sort_order)
   where hub_id = v_auth.hub_id and name = v_old;
  if v_new <> v_old then
    update public.hub_games set category = v_new
     where hub_id = v_auth.hub_id and category = v_old;
  end if;
  return json_build_object('name', v_new, 'renamed_from', v_old);
end $$;

-- 게임 삭제 v2 = 우리 선반에서 내리기 + 우리 허브 평점/후기 삭제.
-- 공용 도감에서는 아무 허브도 안 쓰게 됐을 때만 삭제.
create or replace function public.admin_delete_game(p_player_id text, p_pin text, p_game_id text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_left int;
begin
  v_auth := public._verify_admin(p_player_id, p_pin);
  if coalesce(p_game_id,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.hub_games
                 where hub_id = v_auth.hub_id and game_id = p_game_id) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

  delete from public.ratings   where game_id = p_game_id and hub_id = v_auth.hub_id;
  delete from public.hub_games where game_id = p_game_id and hub_id = v_auth.hub_id;

  select count(*) into v_left from public.hub_games where game_id = p_game_id;
  if v_left = 0 then
    delete from public.games where game_id = p_game_id;
  end if;
  return json_build_object('game_id', p_game_id, 'deleted', true, 'catalog_removed', v_left = 0);
end $$;

-- ============================================================
--  8) 공개 뷰 / RLS / 권한
-- ============================================================

-- players_public: hub_id·status 포함(참가자 자동완성을 허브 멤버로 제한하는 데 사용)
create or replace view public.players_public as
  select player_id, name, role, hub_id, coalesce(status,'active') as status
  from public.players;

alter table public.hubs       enable row level security;
alter table public.hub_admins enable row level security;
alter table public.hub_games  enable row level security;
-- hubs / hub_admins: anon 정책 없음 = 차단 (초대코드 노출 방지, get_hub RPC로만 이름 조회)

drop policy if exists hub_games_read on public.hub_games;
create policy hub_games_read on public.hub_games for select to anon using (true);

grant select on public.players_public to anon;

grant execute on function public.login(text, text, text)                to anon;
grant execute on function public.signup(text, text, text, text)         to anon;
grant execute on function public.get_hub(text)                          to anon;
grant execute on function public.get_games(text)                        to anon;
grant execute on function public.get_plays(text)                        to anon;
grant execute on function public.get_reviews(text, text)                to anon;
grant execute on function public.search_catalog(text, text)             to anon;

-- 끝. 이후 단계(2-1): Supabase Auth 관리자, create_hub RPC, PIN 잠금 본구현(반환값 방식)
