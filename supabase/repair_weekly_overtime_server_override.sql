begin;

-- 이전 버전의 절대 차단을 제거하고 아래의 서버 확인 절차로 대체합니다.
do $$
declare item record; original_definition text; repaired_definition text;
begin
  for item in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('admin_review_overtime','review_correction_request')
  loop
    original_definition := pg_get_functiondef(item.oid);
    repaired_definition := replace(original_definition,
      'if v_week_total + p_approved_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + p_approved_minutes + p_comp_time_minutes > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    repaired_definition := replace(repaired_definition,
      'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;', '');
    if repaired_definition <> original_definition then execute repaired_definition; end if;
  end loop;
end $$;

create table if not exists public.weekly_overtime_override_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.profiles(id) on delete restrict,
  week_start date not null,
  proposed_total_minutes integer not null check (proposed_total_minutes > 720 and proposed_total_minutes <= 10080),
  reason text not null check (char_length(trim(reason)) >= 5),
  acknowledged_by uuid not null references public.profiles(id) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  consumed_at timestamptz,
  consumed_for_type text not null default '',
  consumed_for_id uuid
);

alter table public.weekly_overtime_override_acknowledgements enable row level security;
revoke all on table public.weekly_overtime_override_acknowledgements from public,anon,authenticated;

create or replace function public.acknowledge_weekly_overtime_override(
  p_employee_id uuid,
  p_work_date date,
  p_proposed_total_minutes integer,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_org_id uuid := public.current_profile_org_id();
  v_employee_org_id uuid;
  v_week_start date := date_trunc('week',p_work_date::timestamp)::date;
  v_id uuid;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_proposed_total_minutes <= 720 then raise exception 'WEEKLY_OVERRIDE_NOT_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'WEEKLY_OVERRIDE_REASON_REQUIRED'; end if;
  select org_id into v_employee_org_id from public.profiles where id = p_employee_id and is_active = true;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_role <> 'super_admin' and v_employee_org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;

  insert into public.weekly_overtime_override_acknowledgements (
    org_id,employee_id,week_start,proposed_total_minutes,reason,acknowledged_by
  ) values (
    v_employee_org_id,p_employee_id,v_week_start,p_proposed_total_minutes,trim(p_reason),auth.uid()
  ) returning id into v_id;

  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,reason,
    changed_by,changed_by_role,org_id
  ) values (
    p_employee_id,'weekly_overtime_override_acknowledged','weekly_overtime_minutes',
    '720',p_proposed_total_minutes::text,trim(p_reason),auth.uid(),v_role,v_employee_org_id
  );
  return v_id;
end $$;

create or replace function public.consume_weekly_overtime_override(
  p_employee_id uuid,
  p_work_date date,
  p_proposed_total_minutes integer,
  p_type text,
  p_target_id uuid
) returns void
language plpgsql security definer set search_path = public as $$
declare v_ack_id uuid;
begin
  if p_proposed_total_minutes <= 720 then return; end if;
  select id into v_ack_id
  from public.weekly_overtime_override_acknowledgements
  where employee_id = p_employee_id
    and week_start = date_trunc('week',p_work_date::timestamp)::date
    and proposed_total_minutes = p_proposed_total_minutes
    and acknowledged_by = auth.uid()
    and consumed_at is null
    and acknowledged_at >= now() - interval '10 minutes'
  order by acknowledged_at desc
  limit 1 for update;
  if not found then raise exception 'WEEKLY_OVERTIME_OVERRIDE_REQUIRED'; end if;
  update public.weekly_overtime_override_acknowledgements
  set consumed_at = now(), consumed_for_type = p_type, consumed_for_id = p_target_id
  where id = v_ack_id;
end $$;

create or replace function public.enforce_weekly_override_on_overtime_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_week_start date; v_total integer;
begin
  if new.overtime_status <> 'approved'
     or (tg_op = 'UPDATE' and old.overtime_status = 'approved' and old.approved_overtime_minutes = new.approved_overtime_minutes) then
    return new;
  end if;
  v_week_start := date_trunc('week',new.work_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total
  from public.attendance_records
  where employee_id = new.employee_id and id <> new.id and deleted_at is null
    and overtime_status = 'approved' and work_date between v_week_start and v_week_start + 6;
  select v_total + coalesce(sum(approved_minutes),0)::integer into v_total
  from public.correction_requests
  where employee_id = new.employee_id and request_type = 'emergency_support' and status = 'approved'
    and target_date between v_week_start and v_week_start + 6;
  v_total := v_total + coalesce(new.approved_overtime_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.work_date,v_total,'overtime',new.id);
  return new;
end $$;

create or replace function public.enforce_weekly_override_on_emergency_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_week_start date; v_total integer;
begin
  if new.request_type <> 'emergency_support' or new.status <> 'approved'
     or (tg_op = 'UPDATE' and old.status = 'approved' and old.approved_minutes = new.approved_minutes) then
    return new;
  end if;
  v_week_start := date_trunc('week',new.target_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total
  from public.attendance_records
  where employee_id = new.employee_id and deleted_at is null and overtime_status = 'approved'
    and work_date between v_week_start and v_week_start + 6;
  select v_total + coalesce(sum(approved_minutes),0)::integer into v_total
  from public.correction_requests
  where employee_id = new.employee_id and id <> new.id
    and request_type = 'emergency_support' and status = 'approved'
    and target_date between v_week_start and v_week_start + 6;
  v_total := v_total + coalesce(new.approved_minutes,new.calculated_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.target_date,v_total,'emergency_support',new.id);
  return new;
end $$;

drop trigger if exists enforce_weekly_override_on_overtime_approval_trigger on public.attendance_records;
create trigger enforce_weekly_override_on_overtime_approval_trigger
before insert or update of overtime_status,approved_overtime_minutes on public.attendance_records
for each row execute function public.enforce_weekly_override_on_overtime_approval();

drop trigger if exists enforce_weekly_override_on_emergency_approval_trigger on public.correction_requests;
create trigger enforce_weekly_override_on_emergency_approval_trigger
before insert or update of status,approved_minutes on public.correction_requests
for each row execute function public.enforce_weekly_override_on_emergency_approval();

revoke all on function public.acknowledge_weekly_overtime_override(uuid,date,integer,text) from public,anon;
grant execute on function public.acknowledge_weekly_overtime_override(uuid,date,integer,text) to authenticated;
revoke all on function public.consume_weekly_overtime_override(uuid,date,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.enforce_weekly_override_on_overtime_approval() from public,anon,authenticated;
revoke all on function public.enforce_weekly_override_on_emergency_approval() from public,anon,authenticated;

notify pgrst, 'reload schema';
commit;

select '주 12시간 초과 승인 서버 확인과 감사기록 보완 완료' as result;
