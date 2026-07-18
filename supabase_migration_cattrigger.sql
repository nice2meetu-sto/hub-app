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
