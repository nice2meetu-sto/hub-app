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
