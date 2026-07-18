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
