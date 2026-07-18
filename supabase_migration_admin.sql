-- ============================================================
--  마이그레이션: 관리자 페이지 기능
--  기존 DB에 SQL Editor에서 붙여넣고 Run. (여러 번 실행해도 안전)
--
--  변경 요약
--   - update_play / delete_play : admin이면 본인 기록이 아니어도 수정/삭제 가능
--   - admin_get_players(신규)   : 가입자 목록(닉네임·PIN·가입일) — admin 전용
--   - admin_update_pin(신규)    : 회원 PIN 변경 — admin 전용
--   - admin_add_category(신규)  : 분류 추가 — admin 전용
--   - admin_update_category(신규): 분류 이름/순서 수정(이름 변경 시 games.category도 함께 변경) — admin 전용
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

-- 플레이 수정: 입력자 본인 또는 admin
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

-- 플레이 삭제: 입력자 본인 또는 admin
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

-- 가입자 목록(닉네임·PIN·가입일) — admin 전용
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

-- 회원 PIN 변경 — admin 전용
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

-- 분류 추가 — admin 전용
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

-- 분류 수정(이름/순서). 이름이 바뀌면 games.category 도 함께 변경 — admin 전용
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

-- 실행 권한
grant execute on function public.update_play(text, text, jsonb)                          to anon;
grant execute on function public.delete_play(text, text, text)                           to anon;
grant execute on function public.admin_get_players(text, text)                           to anon;
grant execute on function public.admin_update_pin(text, text, text, text)                to anon;
grant execute on function public.admin_add_category(text, text, text, int)               to anon;
grant execute on function public.admin_update_category(text, text, text, text, int)      to anon;
