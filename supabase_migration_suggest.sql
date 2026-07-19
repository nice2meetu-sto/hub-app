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
