-- ============================================================
--  마이그레이션: 개인설정·의견보내기 + 플레이 기록 수정 권한 확장
--  supabase_migration_idcap.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · update_member_self: PIN 확인으로 내 닉네임/비밀번호 셀프 변경
--    (이메일 연결 없이도 가능 — 닉네임 변경 시 플레이 기록 이름도 동기화)
--  · add_feedback: 앱 사용 의견을 건의 게시판(suggestions)에 남김
--    (game_id는 '' — 게임 수정 요청과 같은 테이블, status로 처리 관리)
--  · update_play/delete_play: '본인이 쓴 기록' 판정을 사람 단위로 확장 —
--    같은 이메일 계정에 연결된 다른 허브 멤버로 쓴 기록도 기록장 등에서
--    바로 수정/삭제 가능 (그 허브에 찾아가지 않아도 됨)
-- ============================================================

-- 1) 내 정보 셀프 변경 (현재 PIN 확인)
create or replace function public.update_member_self(
  p_player_id text, p_pin text, p_name text, p_new_pin text default null)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_name text := btrim(coalesce(p_name, ''));
begin
  v_auth := public._verify(p_player_id, p_pin);

  if v_name <> '' and lower(v_name) <> lower(btrim(v_auth.name)) then
    if exists (select 1 from public.players
               where hub_id = v_auth.hub_id and lower(btrim(name)) = lower(v_name)
                 and player_id <> p_player_id) then
      raise exception '이미 사용 중인 닉네임입니다.'; end if;
    update public.players set name = v_name where player_id = p_player_id;
    -- 플레이 기록의 이름 스냅샷도 함께 갱신
    update public.playlogs set player_name = v_name
     where player_id = p_player_id and coalesce(btrim(player_name), '') <> '';
  end if;

  if coalesce(p_new_pin, '') <> '' then
    if p_new_pin !~ '^\d{4}$' then raise exception '비밀번호는 숫자 4자리로 입력하세요.'; end if;
    update public.players set pin = p_new_pin where player_id = p_player_id;
  end if;

  return json_build_object('player_id', p_player_id,
    'name', case when v_name <> '' then v_name else v_auth.name end,
    'pin_changed', coalesce(p_new_pin, '') <> '');
end $$;

grant execute on function public.update_member_self(text, text, text, text) to anon;
grant execute on function public.update_member_self(text, text, text, text) to authenticated;

-- 2) 의견보내기: 건의 게시판에 일반 의견으로 저장(game_id 없음)
create or replace function public.add_feedback(p_player_id text, p_pin text, p_content text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_auth public.players; v_content text := btrim(coalesce(p_content, ''));
begin
  v_auth := public._verify(p_player_id, p_pin);
  if v_content = '' then raise exception '의견 내용을 입력하세요.'; end if;
  insert into public.suggestions(game_id, player_id, hub_id, content, status, created_at)
  values ('', p_player_id, v_auth.hub_id, v_content, 'open',
          to_char(now(), 'YYYY-MM-DD HH24:MI:SS'));
  return json_build_object('ok', true);
end $$;

grant execute on function public.add_feedback(text, text, text) to anon;
grant execute on function public.add_feedback(text, text, text) to authenticated;

-- 3) 같은 사람(같은 계정에 연결된 멤버) 판정 헬퍼
create or replace function public._same_person(p_a text, p_b text)
returns boolean
language sql stable
set search_path = public
as $$
  select p_a = p_b or exists (
    select 1 from public.players p1
    join public.players p2 on p2.auth_uid = p1.auth_uid
    where p1.player_id = p_a and p1.auth_uid is not null and p2.player_id = p_b);
$$;

-- 4) update_play: 작성자 판정을 사람 단위로
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
  if not public._same_person(p_player_id, v_created)
     and coalesce(v_auth.role,'') <> 'admin' then
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

-- 5) delete_play: 작성자 판정을 사람 단위로
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
  if not public._same_person(p_player_id, v_created)
     and coalesce(v_auth.role,'') <> 'admin' then
    raise exception '본인이 입력한 기록만 삭제할 수 있습니다.'; end if;

  with d as (delete from public.playlogs where session_id = p_session_id returning 1)
    select count(*) into v_del from d;
  return json_build_object('session_id', p_session_id, 'deleted', v_del);
end $$;
