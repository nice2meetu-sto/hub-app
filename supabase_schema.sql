-- ============================================================
--  보드게임 Hub — Supabase 스키마 (테이블 + RPC + RLS)
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run.
--  (여러 번 실행해도 안전하도록 create ... if not exists / or replace 사용)
--
--  구조: 기존 Google Sheets 4장과 동일
--    Players / Games / Ratings / PlayLogs  (+ Categories 분류 목록)
--
--  보안 모델
--    - 조회(select): anon 허용 (단, Players 원본은 pin 보호를 위해 비공개.
--      공개 컬럼만 담은 players_public 뷰로만 노출)
--    - 쓰기: anon 정책 없음 → INSERT/UPDATE/DELETE 전부 차단.
--      모든 쓰기는 PIN을 검증하는 SECURITY DEFINER RPC 함수로만 수행.
-- ============================================================

-- SHA-256(레거시 pin_hash 대조용)에 필요
create extension if not exists pgcrypto with schema extensions;

-- ============================================================
--  1) 테이블 (컬럼명은 기존 시트 헤더와 동일 → CSV import 시 그대로 매핑)
-- ============================================================
create table if not exists public.players (
  player_id text primary key,
  name      text not null unique,
  pin_hash  text,          -- 레거시(평문 pin이 비어있을 때만 사용)
  pin       text,          -- 평문 PIN (이 값을 고치면 비밀번호가 바뀜)
  role      text not null default 'member',
  joined_at text
);

create table if not exists public.games (
  game_id      text primary key,
  name_kr      text,
  name_en      text,
  category     text,
  min_players  numeric,
  max_players  numeric,
  playtime_min numeric,
  weight       numeric,
  summary_kr   text,
  image_url    text,
  source       text,
  created_by   text,
  created_at   text
);

create table if not exists public.ratings (
  player_id  text not null,
  game_id    text not null,
  rating     numeric,
  memo       text,          -- 개인 게임메모(비공개)
  review     text,          -- 공개 후기(게임 탭에 노출)
  updated_at text,
  primary key (player_id, game_id)
);
-- 기존 DB에 review 컬럼이 없으면 추가
alter table public.ratings add column if not exists review text;

create table if not exists public.playlogs (
  record_id    text primary key,
  session_id   text,
  play_date    text,          -- 'YYYY-MM-DD' 문자열로 저장(시트와 동일, TZ 이슈 회피)
  game_id      text,
  duration_min numeric,
  player_id    text,          -- 게스트(비회원)는 NULL
  player_name  text,
  score        numeric,
  is_win       boolean,
  created_by   text,          -- 입력자(본인만 수정/삭제 가능)
  created_at   text
);

create table if not exists public.categories (
  name       text primary key,
  sort_order int default 0
);

-- 분류 기본값(비어 있을 때만 채움)
insert into public.categories(name, sort_order) values
  ('전략',1),('마피아',2),('트릭테이킹',3),('파티',4),('협력',5),
  ('덱빌딩',6),('추리',7),('가족',8),('아브스트랙트',9),('기타',10)
on conflict (name) do nothing;

-- 조회 성능용 인덱스
create index if not exists idx_playlogs_session on public.playlogs(session_id);
create index if not exists idx_playlogs_player  on public.playlogs(player_id);
create index if not exists idx_playlogs_game    on public.playlogs(game_id);
create index if not exists idx_ratings_game     on public.ratings(game_id);

-- ============================================================
--  2) 내부 헬퍼 (anon 에 실행 권한 부여하지 않음 — RPC 내부에서만 호출)
-- ============================================================

-- PIN 검증: 평문 pin 우선, 비어있으면 pin_hash(SHA-256)로 대조. 성공 시 player row 반환.
create or replace function public._verify(p_player_id text, p_pin text)
returns public.players
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  select * into r from public.players where player_id = p_player_id;
  if not found then raise exception '사용자를 찾을 수 없습니다.'; end if;
  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then raise exception 'PIN이 올바르지 않습니다.'; end if;
  return r;
end $$;

-- 다음 ID: prefix + zero-pad(최대 숫자접미사 + 1). 예) P001, G001, S0001
create or replace function public._next_id(p_prefix text, p_pad int, p_table text, p_col text)
returns text
language plpgsql stable security definer
set search_path = public
as $$
declare v_max int;
begin
  execute format(
    'select coalesce(max((substring(%I from %L))::int), 0) from public.%I',
    p_col, '^' || p_prefix || '([0-9]+)$', p_table
  ) into v_max;
  return p_prefix || lpad((v_max + 1)::text, p_pad, '0');
end $$;

-- ============================================================
--  3) 인증 RPC
-- ============================================================

-- 로그인: 이름 + PIN 대조. pin은 절대 반환하지 않음.
create or replace function public.login(p_name text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  if coalesce(p_name,'') = '' or coalesce(p_pin,'') = '' then
    raise exception '이름과 PIN을 입력하세요.'; end if;
  select * into r from public.players where name = p_name;
  if not found then raise exception '사용자를 찾을 수 없습니다.'; end if;
  if not (
    case when coalesce(btrim(r.pin), '') <> ''
         then btrim(r.pin) = btrim(p_pin)
         else r.pin_hash = encode(digest(p_pin, 'sha256'), 'hex')
    end
  ) then raise exception 'PIN이 올바르지 않습니다.'; end if;
  return json_build_object('player_id', r.player_id, 'name', r.name, 'role', coalesce(r.role,'member'));
end $$;

-- 회원가입: 닉네임 + 숫자 4자리 PIN. 첫 가입자는 admin.
create or replace function public.signup(p_name text, p_pin text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_name text := btrim(p_name); v_pin text := btrim(p_pin);
        v_id text; v_role text; v_cnt int;
begin
  if v_name = '' then raise exception '닉네임을 입력하세요.'; end if;
  if length(v_name) > 20 then raise exception '닉네임은 20자 이하로 입력하세요.'; end if;
  if v_pin !~ '^\d{4}$' then raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;
  if exists (select 1 from public.players where btrim(name) = v_name) then
    raise exception '이미 사용 중인 닉네임입니다.'; end if;

  select count(*) into v_cnt from public.players;
  v_role := case when v_cnt = 0 then 'admin' else 'member' end;
  v_id := public._next_id('P', 3, 'players', 'player_id');

  insert into public.players(player_id, name, pin, role, joined_at)
  values (v_id, v_name, v_pin, v_role, to_char(now(), 'YYYY-MM-DD'));

  return json_build_object('player_id', v_id, 'name', v_name, 'role', v_role);
end $$;

-- ============================================================
--  4) 조회 RPC (anon 실행 허용) — 반환 형태를 기존 Apps Script와 동일하게 유지
-- ============================================================

-- 게임 목록 + 우리Hub평점(평균)·평가수·플레이수 집계
create or replace function public.get_games()
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
    from public.playlogs group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', g.category, 'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.games g
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id;
$$;

-- 플레이 세션 목록(참가자 배열 포함), 최신순
create or replace function public.get_plays()
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
  ),
  sess as (
    select s.session_id, s.play_date, s.game_id, s.duration_min, s.created_by,
           g.name_kr, g.name_en, g.image_url
    from (
      select distinct on (session_id)
             session_id, play_date, game_id, duration_min, created_by
      from public.playlogs
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

-- 개인 통계(총 플레이/승/승률/이번달/최근6개월/게임별)
create or replace function public.get_player_stats(p_player_id text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_total int; v_wins int; v_rate numeric; v_this int;
  v_monthly json; v_bygame json;
  v_thismonth text := to_char(now(), 'YYYY-MM');
begin
  if coalesce(p_player_id,'') = '' then raise exception 'playerId가 필요합니다.'; end if;

  select count(*), count(*) filter (where is_win)
    into v_total, v_wins
  from public.playlogs where player_id = p_player_id;

  v_rate := case when v_total > 0 then round(v_wins::numeric / v_total * 100, 1) else 0 end;

  select count(*) into v_this from public.playlogs
   where player_id = p_player_id and substring(play_date from 1 for 7) = v_thismonth;

  -- 최근 6개월(오래된→최신): 판수 + 승수/승률 포함
  select json_agg(json_build_object(
           'month', months.m,
           'count', coalesce(agg.c, 0),
           'wins',  coalesce(agg.w, 0),
           'win_rate', case when coalesce(agg.c, 0) > 0
                            then round(agg.w::numeric / agg.c * 100, 1) else 0 end
         ) order by months.m)
    into v_monthly
  from (
    select to_char(date_trunc('month', now()) - (i || ' month')::interval, 'YYYY-MM') as m
    from generate_series(5, 0, -1) as i
  ) months
  left join (
    select substring(play_date from 1 for 7) as ym,
           count(*) c, count(*) filter (where is_win) w
    from public.playlogs where player_id = p_player_id group by 1
  ) agg on agg.ym = months.m;

  -- 게임별(승률↓, 판수↓)
  select coalesce(json_agg(json_build_object(
    'game_id',  t.game_id,
    'game',     coalesce(g.name_kr, g.name_en, t.game_id),
    'image_url',coalesce(g.image_url, ''),
    'plays',    t.plays,
    'wins',     t.wins,
    'win_rate', case when t.plays > 0 then round(t.wins::numeric / t.plays * 100, 1) else 0 end
  ) order by (case when t.plays > 0 then t.wins::numeric / t.plays else 0 end) desc, t.plays desc), '[]'::json)
    into v_bygame
  from (
    select game_id, count(*) plays, count(*) filter (where is_win) wins
    from public.playlogs where player_id = p_player_id group by game_id
  ) t
  left join public.games g on g.game_id = t.game_id;

  return json_build_object(
    'total_plays', v_total, 'total_wins', v_wins, 'win_rate', v_rate,
    'this_month_plays', v_this,
    'monthly', coalesce(v_monthly, '[]'::json),
    'by_game', v_bygame
  );
end $$;

-- 내 평점 목록
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
  where r.player_id = p_player_id;
$$;

-- ============================================================
--  5) 쓰기 RPC (PIN 검증 후 실행) — 클라이언트 직접 INSERT/UPDATE 없음
-- ============================================================

-- 평점만 저장(후기/메모는 건드리지 않음). 평점·후기 독립 저장.
drop function if exists public.save_rating(text, text, text, numeric, text);
create or replace function public.save_rating(
  p_player_id text, p_pin text, p_game_id text, p_rating numeric)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  if p_rating is null or p_rating < 1 or p_rating > 10 then
    raise exception '평점은 1~10 사이여야 합니다.'; end if;
  insert into public.ratings(player_id, game_id, rating, updated_at)
  values (p_player_id, p_game_id, p_rating, v_now)
  on conflict (player_id, game_id) do update
    set rating = excluded.rating, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'rating', p_rating, 'updated_at', v_now);
end $$;

-- 공개 후기만 저장(평점/메모는 건드리지 않음)
create or replace function public.save_review(
  p_player_id text, p_pin text, p_game_id text, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, review, updated_at)
  values (p_player_id, p_game_id, coalesce(p_review, ''), v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;

-- 개인 게임메모(비공개) 저장. 평점/후기는 건드리지 않음.
create or replace function public.save_memo(
  p_player_id text, p_pin text, p_game_id text, p_memo text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, memo, updated_at)
  values (p_player_id, p_game_id, coalesce(p_memo, ''), v_now)
  on conflict (player_id, game_id) do update
    set memo = excluded.memo, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'memo', coalesce(p_memo, ''));
end $$;

-- 게임별 공개 후기 목록(닉네임 + 후기), 최신순
create or replace function public.get_reviews(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  where r.game_id = p_game_id and r.review is not null and btrim(r.review) <> '';
$$;

-- 플레이 결과 추가(세션 1건 = 참가자 여러 행)
create or replace function public.add_play(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_sid text; v_maxrec int; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
  v_date text; v_dur numeric; v_gid text; v_part jsonb; v_count int;
begin
  perform public._verify(p_player_id, p_pin);
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
      record_id, session_id, play_date, game_id, duration_min,
      player_id, player_name, score, is_win, created_by, created_at)
    values(
      'R' || lpad(v_maxrec::text, 5, '0'), v_sid, v_date, v_gid, v_dur,
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

-- 플레이 세션 수정(날짜·시간·참가자별 점수/승패). 입력자 본인만.
create or replace function public.update_play(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_sid text; v_created text; v_date text; v_dur numeric; v_cnt int; v_row jsonb;
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_sid := p_payload->>'session_id';
  if coalesce(v_sid,'') = '' then raise exception 'session_id가 필요합니다.'; end if;

  select created_by into v_created from public.playlogs where session_id = v_sid limit 1;
  if v_created is null then raise exception '기록을 찾을 수 없습니다.'; end if;
  if v_created <> p_player_id and coalesce(v_auth.role,'') <> 'admin' then
    raise exception '본인이 입력한 기록만 수정할 수 있습니다.'; end if;

  v_date := nullif(p_payload->>'play_date','');
  v_dur  := nullif(p_payload->>'duration_min','')::numeric;

  update public.playlogs
     set play_date = coalesce(v_date, play_date),
         duration_min = v_dur
   where session_id = v_sid;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'rows','[]'::jsonb)) loop
    update public.playlogs
       set score  = nullif(v_row->>'score','')::numeric,
           is_win = coalesce((v_row->>'is_win')::boolean, false)
     where record_id = v_row->>'record_id' and session_id = v_sid;
  end loop;

  select count(*) into v_cnt from public.playlogs where session_id = v_sid;
  return json_build_object('session_id', v_sid, 'updated', v_cnt);
end $$;

-- 플레이 세션 삭제(그 세션의 모든 참가자 행). 입력자 본인만.
create or replace function public.delete_play(p_player_id text, p_pin text, p_session_id text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_created text; v_del int;
begin
  v_auth := public._verify(p_player_id, p_pin);
  if coalesce(p_session_id,'') = '' then raise exception 'session_id가 필요합니다.'; end if;

  select created_by into v_created from public.playlogs where session_id = p_session_id limit 1;
  if v_created is null then raise exception '기록을 찾을 수 없습니다.'; end if;
  if v_created <> p_player_id and coalesce(v_auth.role,'') <> 'admin' then
    raise exception '본인이 입력한 기록만 삭제할 수 있습니다.'; end if;

  with d as (delete from public.playlogs where session_id = p_session_id returning 1)
    select count(*) into v_del from d;
  return json_build_object('session_id', p_session_id, 'deleted', v_del);
end $$;

-- 게임 추가(로그인 회원 누구나)
create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id text; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  if btrim(coalesce(p_payload->>'name_kr','')) = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if exists (select 1 from public.games
             where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g')
                 = regexp_replace(lower(btrim(coalesce(p_payload->>'name_kr',''))), '\s+', '', 'g')) then
    raise exception '이미 등록된 게임명입니다.'; end if;
  v_id := public._next_id('G', 3, 'games', 'game_id');

  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, playtime_min, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id,
    btrim(coalesce(p_payload->>'name_kr','')), coalesce(p_payload->>'name_en',''),
    coalesce(p_payload->>'category',''),
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'playtime_min','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );

  return json_build_object('game_id', v_id, 'name_kr', coalesce(p_payload->>'name_kr',''), 'source', 'manual');
end $$;

-- 게임 정보 수정(관리자만)
create or replace function public.update_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_role text; v_gid text;
begin
  perform public._verify(p_player_id, p_pin);
  select role into v_role from public.players where player_id = p_player_id;
  if coalesce(v_role,'') <> 'admin' then raise exception '관리자만 수정할 수 있습니다.'; end if;

  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.games where game_id = v_gid) then
    raise exception '게임을 찾을 수 없습니다.'; end if;

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

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;

-- ============================================================
--  6) 공개 뷰: Players 에서 pin/pin_hash 제외한 안전 컬럼만 노출
-- ============================================================
create or replace view public.players_public as
  select player_id, name, role from public.players;

-- ============================================================
--  7) RLS 정책
--     조회(select): anon 허용 (Players 원본 제외)
--     쓰기: 정책 없음 → 전부 차단(오직 SECURITY DEFINER RPC 로만)
-- ============================================================
alter table public.players    enable row level security;
alter table public.games      enable row level security;
alter table public.ratings    enable row level security;
alter table public.playlogs   enable row level security;
alter table public.categories enable row level security;

-- Players 원본: anon select 정책 없음(=차단). pin 노출 방지.

drop policy if exists games_read on public.games;
create policy games_read on public.games for select to anon using (true);

drop policy if exists ratings_read on public.ratings;
create policy ratings_read on public.ratings for select to anon using (true);

drop policy if exists playlogs_read on public.playlogs;
create policy playlogs_read on public.playlogs for select to anon using (true);

drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to anon using (true);

-- ============================================================
--  8) 실행 권한
--     - 공개 뷰 select 허용
--     - 조회/쓰기 RPC 실행 허용
--     - 내부 헬퍼(_verify/_next_id)는 anon 에 부여하지 않음(RPC 내부에서만 호출됨)
-- ============================================================
grant usage on schema public to anon;
grant select on public.players_public to anon;

grant execute on function public.login(text, text)                                  to anon;
grant execute on function public.signup(text, text)                                 to anon;
grant execute on function public.get_games()                                        to anon;
grant execute on function public.get_plays()                                        to anon;
grant execute on function public.get_player_stats(text)                             to anon;
grant execute on function public.get_my_ratings(text)                               to anon;
grant execute on function public.save_rating(text, text, text, numeric)             to anon;
grant execute on function public.save_review(text, text, text, text)                to anon;
grant execute on function public.save_memo(text, text, text, text)                  to anon;
grant execute on function public.get_reviews(text)                                  to anon;
grant execute on function public.add_play(text, text, jsonb)                        to anon;
grant execute on function public.update_play(text, text, jsonb)                     to anon;
grant execute on function public.delete_play(text, text, text)                      to anon;
grant execute on function public.add_game(text, text, jsonb)                        to anon;
grant execute on function public.update_game(text, text, jsonb)                     to anon;

-- 내부 헬퍼는 anon 실행 권한 회수(있다면)
revoke all on function public._verify(text, text)            from anon, public;
revoke all on function public._next_id(text, int, text, text) from anon, public;


-- ============================================================
--  9) 관리자 페이지 RPC (admin 전용)
-- ============================================================

-- 관리자 검증 헬퍼: PIN 검증 후 admin 아니면 예외
create or replace function public._verify_admin(p_player_id text, p_pin text)
returns public.players
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  r := public._verify(p_player_id, p_pin);
  if coalesce(r.role, '') <> 'admin' then raise exception '관리자만 사용할 수 있습니다.'; end if;
  return r;
end $$;
revoke all on function public._verify_admin(text, text) from anon, public;

-- 가입자 목록(닉네임·PIN·가입일)
create or replace function public.admin_get_players(p_player_id text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
begin
  perform public._verify_admin(p_player_id, p_pin);
  return (select coalesce(json_agg(json_build_object(
    'player_id', player_id, 'name', name, 'pin', coalesce(pin, ''),
    'role', coalesce(role, 'member'), 'joined_at', coalesce(joined_at, '')
  ) order by player_id), '[]'::json) from public.players);
end $$;

-- 회원 PIN 변경
create or replace function public.admin_update_pin(
  p_player_id text, p_pin text, p_target_id text, p_new_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public._verify_admin(p_player_id, p_pin);
  if btrim(coalesce(p_new_pin,'')) !~ '^\d{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;
  update public.players set pin = btrim(p_new_pin) where player_id = p_target_id;
  if not found then raise exception '회원을 찾을 수 없습니다.'; end if;
  return json_build_object('player_id', p_target_id, 'updated', true);
end $$;

-- 분류 추가
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

-- 분류 수정(이름/순서). 이름 변경 시 games.category 도 함께 변경
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

grant execute on function public.admin_get_players(text, text)                       to anon;
grant execute on function public.admin_update_pin(text, text, text, text)            to anon;
grant execute on function public.admin_add_category(text, text, text, int)           to anon;
grant execute on function public.admin_update_category(text, text, text, text, int)  to anon;

-- 게임 삭제(관리자 전용): 게임 + 그 게임의 평점/후기 삭제. 플레이 기록은 보존.
create or replace function public.admin_delete_game(p_player_id text, p_pin text, p_game_id text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public._verify_admin(p_player_id, p_pin);
  if coalesce(p_game_id,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  if not exists (select 1 from public.games where game_id = p_game_id) then
    raise exception '게임을 찾을 수 없습니다.'; end if;
  delete from public.ratings where game_id = p_game_id;
  delete from public.games   where game_id = p_game_id;
  return json_build_object('game_id', p_game_id, 'deleted', true);
end $$;
grant execute on function public.admin_delete_game(text, text, text)                   to anon;

-- 끝. (데이터는 README의 CSV import 단계에서 채웁니다.)
