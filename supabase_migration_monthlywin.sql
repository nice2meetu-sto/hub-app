-- ============================================================
--  마이그레이션: 월별 통계에 승수/승률(wins, win_rate) 추가
--  SQL Editor에 붙여넣고 Run. 여러 번 실행해도 안전.
--
--  My-전체기록의 월별 그래프에서 판수와 함께 승률 막대를 그리기 위해
--  get_player_stats 의 monthly 배열에 wins, win_rate 를 함께 반환합니다.
--  (이미 훑는 playlogs 에 집계 한 줄을 얹는 것뿐이라 부담 없음)
-- ============================================================

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

grant execute on function public.get_player_stats(text) to anon;
