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
