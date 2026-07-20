-- ============================================================
--  마이그레이션: 공용 기본 카테고리에 '기타' 추가(8종 → 9종)
--  supabase_fix_all.sql 실행 후에 Run. 여러 번 실행해도 안전.
--
--  · 새로 개설되는 허브는 기본 분류 9종(…협력게임, 기타)으로 시작
--  · 기존 허브에도 '기타' 분류를 추가(백필)
-- ============================================================

-- 1) 기존 모든 허브에 '기타' 분류 추가(정렬 9)
insert into public.categories(hub_id, name, sort_order)
select h.hub_id, '기타', 9
from public.hubs h
on conflict (hub_id, name) do nothing;

-- 2) create_hub: 새 허브 개설 시 기본 분류에 '기타' 포함
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
  if char_length(v_icon) > 8
     or v_icon ~ '[A-Za-z0-9가-힣ㄱ-ㅎㅏ-ㅣ]' then
    raise exception '아이콘은 이모지 1개만 넣어주세요.'; end if;
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
    (v_id,'1대1 게임',5),(v_id,'카드게임',6),(v_id,'경매게임',7),(v_id,'협력게임',8),(v_id,'기타',9)
  on conflict (hub_id, name) do nothing;

  return json_build_object('hub_id', v_id, 'name', v_name, 'invite_code', v_code,
                           'icon', v_icon, 'existing', false);
end $$;
grant execute on function public.create_hub(text, text, text) to authenticated;
