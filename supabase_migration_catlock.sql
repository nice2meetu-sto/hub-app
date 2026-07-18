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
