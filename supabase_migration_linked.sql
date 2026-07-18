-- ============================================================
--  마이그레이션: 이메일 연동 통합 기록 (ROADMAP 2-5)
--  supabase_migration_uiapi.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · players_public에 linked(계정 연결 여부) 추가
--  · get_my_links: 내 계정에 연결된 허브·멤버 목록
--  · get_my_stats_all: 연결된 전 허브 기록을 합산한 통합 개인 통계
--    (get_player_stats와 동일한 형태 → 프론트 렌더 재사용)
-- ============================================================

create or replace view public.players_public as
  select player_id, name, role, hub_id,
         coalesce(status,'active') as status,
         (auth_uid is not null) as linked
  from public.players;
grant select on public.players_public to anon;

-- 내 계정에 연결된 멤버 목록(허브 이름 포함)
create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name,
    'player_id', p.player_id, 'name', p.name,
    'status', coalesce(p.status,'active')
  ) order by p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid();
$$;

-- 통합 개인 통계: 연결된 전 멤버(허브)의 플레이를 합산.
-- 게임은 공용 도감이라 game_id 기준으로 허브 간 기록이 자연 합산됨.
create or replace function public.get_my_stats_all()
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_total int; v_wins int; v_rate numeric; v_this int;
  v_monthly json; v_bygame json;
  v_thismonth text := to_char(now(), 'YYYY-MM');
begin
  if auth.uid() is null then raise exception '이메일 로그인이 필요합니다.'; end if;

  select count(*), count(*) filter (where is_win)
    into v_total, v_wins
  from public.playlogs where player_id in (select player_id from public.players where auth_uid = auth.uid());

  v_rate := case when v_total > 0 then round(v_wins::numeric / v_total * 100, 1) else 0 end;

  select count(*) into v_this from public.playlogs
   where player_id in (select player_id from public.players where auth_uid = auth.uid())
     and substring(play_date from 1 for 7) = v_thismonth;

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
    from public.playlogs where player_id in (select player_id from public.players where auth_uid = auth.uid()) group by 1
  ) agg on agg.ym = months.m;

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
    from public.playlogs where player_id in (select player_id from public.players where auth_uid = auth.uid()) group by game_id
  ) t
  left join public.games g on g.game_id = t.game_id;

  return json_build_object(
    'total_plays', v_total, 'total_wins', v_wins, 'win_rate', v_rate,
    'this_month_plays', v_this,
    'monthly', coalesce(v_monthly, '[]'::json),
    'by_game', v_bygame
  );
end $$;

revoke all on function public.get_my_links()     from anon, public;
revoke all on function public.get_my_stats_all() from anon, public;
grant execute on function public.get_my_links()     to authenticated;
grant execute on function public.get_my_stats_all() to authenticated;
