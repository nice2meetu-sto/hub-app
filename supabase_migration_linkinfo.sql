-- ============================================================
--  마이그레이션: 닉네임/PIN 로그인 사용자도 연결된 이메일 확인·해제
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · get_linked_email: 본인 PIN 확인 후, 이 멤버에 연결된 이메일을
--    마스킹해서 반환(앞 2글자 + ***** + @도메인). 다른 사람이 연결한
--    경우에도 원본 이메일은 노출하지 않음(서버에서 마스킹).
--  · unlink_by_pin: 본인 PIN 확인 후 이메일 연결 해제(auth_uid = null)
-- ============================================================

create or replace function public.get_linked_email(p_player_id text, p_pin text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r public.players; v_email text; v_local text; v_domain text;
begin
  r := public._verify(p_player_id, p_pin);   -- 본인 PIN 확인(실패 시 예외)
  if r.auth_uid is null then
    return json_build_object('linked', false);
  end if;
  select email into v_email from auth.users where id = r.auth_uid;
  if coalesce(v_email, '') = '' then
    return json_build_object('linked', true, 'email', null);
  end if;
  v_local  := split_part(v_email, '@', 1);
  v_domain := split_part(v_email, '@', 2);
  return json_build_object(
    'linked', true,
    'email', left(v_local, 2) || '*****'
             || case when v_domain <> '' then '@' || v_domain else '' end
  );
end $$;
grant execute on function public.get_linked_email(text, text) to anon;

create or replace function public.unlink_by_pin(p_player_id text, p_pin text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare r public.players;
begin
  r := public._verify(p_player_id, p_pin);   -- 본인 PIN 확인(실패 시 예외)
  update public.players set auth_uid = null where player_id = r.player_id;
  return json_build_object('ok', true);
end $$;
grant execute on function public.unlink_by_pin(text, text) to anon;
