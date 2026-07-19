-- ============================================================
--  마이그레이션: 허브 아이콘(이모지 1개)
--  supabase_migration_selfserve.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · hubs.icon: 허브별 이모지 아이콘 — 기본 🎲, 기록장은 📔 고정
--  · create_hub: 개설 시 아이콘 지정(p_icon) — 기록장은 항상 📔 자동
--  · hub_set_icon: 허브 설정에서 변경(개설 계정 전용, 기록장은 불가)
--  · get_hub / hub_by_invite / get_my_links / my_hubs 에 icon 포함
-- ============================================================

alter table public.hubs add column if not exists icon text default '';

-- 1) create_hub: 아이콘 파라미터 추가(구버전 시그니처 제거 후 재생성)
drop function if exists public.create_hub(text, text);
create or replace function public.create_hub(p_name text, p_kind text default 'hub', p_icon text default '')
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := public._auth_uid(); v_id text; v_code text; h public.hubs;
        v_name text := btrim(coalesce(p_name,''));
        v_kind text := case when p_kind = 'personal' then 'personal' else 'hub' end;
        v_icon text := btrim(coalesce(p_icon,''));
begin
  if v_uid is null then raise exception '허브 개설에는 이메일 로그인이 필요합니다.'; end if;
  if v_name = '' then raise exception '허브 이름을 입력하세요.'; end if;
  if length(v_name) > 30 then raise exception '허브 이름은 30자 이하로 입력하세요.'; end if;
  if char_length(v_icon) > 8 then raise exception '아이콘은 이모지 1개만 넣어주세요.'; end if;
  -- 기록장은 자동 개설이라 📔 고정, 허브는 지정 없으면 기본 🎲
  v_icon := case when v_kind = 'personal' then '📔'
                 when v_icon = '' then '🎲' else v_icon end;

  if v_kind = 'personal' then
    select * into h from public.hubs
     where owner_uid = v_uid and kind = 'personal'
     order by hub_id limit 1;
    if found then
      return json_build_object('hub_id', h.hub_id, 'name', h.name,
                               'invite_code', h.invite_code, 'existing', true);
    end if;
  end if;

  v_id := public._next_id('H', 3, 'hubs', 'hub_id');
  v_code := upper(substring(md5(random()::text) from 1 for 6));
  insert into public.hubs(hub_id, name, invite_code, owner_uid, created_at, kind, icon)
  values (v_id, v_name, v_code, v_uid, to_char(now(), 'YYYY-MM-DD'), v_kind, v_icon);

  insert into public.categories(hub_id, name, sort_order) values
    (v_id,'전략',1),(v_id,'마피아',2),(v_id,'파티게임',3),(v_id,'트릭테이킹',4),
    (v_id,'1대1 게임',5),(v_id,'카드게임',6),(v_id,'경매게임',7),(v_id,'협력게임',8)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code,
                           'icon', v_icon, 'existing', false);
end $$;
grant execute on function public.create_hub(text, text, text) to authenticated;

-- 2) 아이콘 변경(개설 계정 전용, 기록장 불가)
create or replace function public.hub_set_icon(p_hub_id text, p_icon text)
returns json
language plpgsql security definer
set search_path = public
as $$
declare v_icon text := btrim(coalesce(p_icon,''));
begin
  perform public._verify_hub_auth(p_hub_id);
  if exists (select 1 from public.hubs where hub_id = p_hub_id and kind = 'personal') then
    raise exception '기록장 아이콘은 바꿀 수 없어요.'; end if;
  if v_icon = '' then v_icon := '🎲'; end if;
  if char_length(v_icon) > 8 then raise exception '아이콘은 이모지 1개만 넣어주세요.'; end if;
  update public.hubs set icon = v_icon where hub_id = p_hub_id;
  return json_build_object('hub_id', p_hub_id, 'icon', v_icon);
end $$;
revoke all on function public.hub_set_icon(text, text) from anon, public;
grant execute on function public.hub_set_icon(text, text) to authenticated;

-- 3) 조회 RPC들에 icon 포함
create or replace function public.get_hub(p_hub_id text default 'H001')
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object('hub_id', hub_id, 'name', name, 'kind', coalesce(kind,'hub'),
                           'icon', coalesce(icon,''))
  from public.hubs where hub_id = p_hub_id;
$$;

create or replace function public.hub_by_invite(p_code text)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare h public.hubs;
begin
  if btrim(coalesce(p_code,'')) = '' then
    raise exception '초대코드를 입력하세요.'; end if;
  select * into h from public.hubs
   where upper(invite_code) = upper(btrim(p_code));
  if not found then raise exception '초대코드가 올바르지 않습니다.'; end if;
  return json_build_object('hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
                           'icon', coalesce(h.icon,''));
end $$;

create or replace function public.get_my_links()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', p.hub_id, 'hub_name', h.name, 'kind', coalesce(h.kind,'hub'),
    'icon', coalesce(h.icon,''),
    'invite', coalesce(h.invite_code, ''),
    'player_id', p.player_id, 'name', p.name, 'pin', coalesce(p.pin, ''),
    'status', coalesce(p.status,'active')
  ) order by (coalesce(h.kind,'hub') = 'personal') desc, p.hub_id), '[]'::json)
  from public.players p
  join public.hubs h on h.hub_id = p.hub_id
  where p.auth_uid = auth.uid();
$$;

create or replace function public.my_hubs()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'hub_id', h.hub_id, 'name', h.name, 'kind', coalesce(h.kind,'hub'),
    'icon', coalesce(h.icon,''),
    'is_owner', (h.owner_uid = public._auth_uid())
  ) order by h.hub_id), '[]'::json)
  from public.hubs h
  where h.owner_uid = public._auth_uid()
     or exists (select 1 from public.hub_admins a
                where a.hub_id = h.hub_id and a.auth_uid = public._auth_uid());
$$;

-- 4) 기존 데이터 기본값: 기록장 📔, 허브 🎲 (비어있는 것만)
update public.hubs set icon = case when coalesce(kind,'hub') = 'personal' then '📔' else '🎲' end
 where coalesce(icon,'') = '';
