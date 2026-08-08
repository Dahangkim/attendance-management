-- 연차와 대체휴무 잔액, 특별휴가 보완
-- 기존 승인 이력은 보존하고 이후 승인부터 잔액 부족을 차단합니다.

begin;

alter table public.correction_requests drop constraint if exists correction_requests_request_type_check;
alter table public.correction_requests
  add constraint correction_requests_request_type_check
  check (request_type in (
    'clock_in_at','clock_out_at','annual_leave','comp_time','special_leave','sick_leave',
    'business_trip','overtime','other_leave','work_type','note','attendance_status'
  )) not valid;

alter table public.attendance_exceptions drop constraint if exists attendance_exceptions_exception_type_check;
alter table public.attendance_exceptions
  add constraint attendance_exceptions_exception_type_check
  check (exception_type in (
    'business_trip','external_training','approved_other','annual_leave','comp_time',
    'special_leave','sick_leave','other_leave'
  )) not valid;

create table if not exists public.annual_leave_entitlements (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete restrict,
  valid_from date not null,
  valid_to date not null,
  base_minutes integer not null default 0 check (base_minutes >= 0 and base_minutes % 60 = 0),
  carryover_minutes integer not null default 0 check (carryover_minutes >= 0 and carryover_minutes % 60 = 0),
  adjustment_minutes integer not null default 0 check (adjustment_minutes % 60 = 0),
  reason text not null default '',
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  delete_reason text not null default '',
  check (valid_to >= valid_from),
  check (base_minutes + carryover_minutes + adjustment_minutes >= 0)
);

alter table public.annual_leave_entitlements add column if not exists deleted_at timestamptz;
alter table public.annual_leave_entitlements add column if not exists deleted_by uuid references public.profiles(id) on delete restrict;
alter table public.annual_leave_entitlements add column if not exists delete_reason text not null default '';

create index if not exists annual_leave_entitlements_employee_period_idx
  on public.annual_leave_entitlements (employee_id, valid_from, valid_to);

alter table public.comp_time_credits alter column attendance_record_id drop not null;
alter table public.comp_time_credits add column if not exists source_type text not null default 'overtime';
alter table public.comp_time_credits add column if not exists source_date date;
update public.comp_time_credits credit
set source_date = attendance.work_date
from public.attendance_records attendance
where attendance.id = credit.attendance_record_id and credit.source_date is null;
update public.comp_time_credits set source_date = granted_at::date where source_date is null;
alter table public.comp_time_credits alter column source_date set not null;

alter table public.comp_time_credits drop constraint if exists comp_time_credits_source_type_check;
alter table public.comp_time_credits
  add constraint comp_time_credits_source_type_check
  check (source_type in ('overtime','opening_balance','admin_adjustment')) not valid;

alter table public.annual_leave_entitlements enable row level security;
drop policy if exists "own or admin annual entitlements read" on public.annual_leave_entitlements;
create policy "own or admin annual entitlements read" on public.annual_leave_entitlements
for select to authenticated using (
  employee_id = auth.uid()
  or public.is_attendance_admin()
  or public.can_view_attendance_reports()
);
revoke insert, update, delete on public.annual_leave_entitlements from authenticated;

drop view if exists public.annual_leave_balances_view;
create view public.annual_leave_balances_view with (security_invoker = true) as
select
  entitlement.id as entitlement_id,
  entitlement.employee_id,
  profile.name as employee_name,
  entitlement.valid_from,
  entitlement.valid_to,
  entitlement.base_minutes,
  entitlement.carryover_minutes,
  entitlement.adjustment_minutes,
  (entitlement.base_minutes + entitlement.carryover_minutes + entitlement.adjustment_minutes)::integer as granted_minutes,
  coalesce(usage.used_minutes,0)::integer as used_minutes,
  coalesce(usage.scheduled_minutes,0)::integer as scheduled_minutes,
  greatest(0,
    entitlement.base_minutes + entitlement.carryover_minutes + entitlement.adjustment_minutes
    - coalesce(usage.used_minutes,0) - coalesce(usage.scheduled_minutes,0)
  )::integer as remaining_minutes,
  entitlement.reason,
  entitlement.created_at,
  entitlement.updated_at
from public.annual_leave_entitlements entitlement
join public.profiles profile on profile.id = entitlement.employee_id
left join lateral (
  select
    coalesce(sum(case when request.target_date < (now() at time zone 'Asia/Seoul')::date
      then coalesce(nullif(request.approved_minutes,0),request.calculated_minutes) else 0 end),0)::integer as used_minutes,
    coalesce(sum(case when request.target_date >= (now() at time zone 'Asia/Seoul')::date
      then coalesce(nullif(request.approved_minutes,0),request.calculated_minutes) else 0 end),0)::integer as scheduled_minutes
  from public.correction_requests request
  where request.employee_id = entitlement.employee_id
    and request.request_type = 'annual_leave'
    and request.status = 'approved'
    and request.target_date >= entitlement.valid_from
    and coalesce(request.end_date,request.target_date) <= entitlement.valid_to
) usage on true
where entitlement.deleted_at is null;

grant select on public.annual_leave_balances_view to authenticated;

drop view if exists public.comp_time_credit_details_view;
create view public.comp_time_credit_details_view with (security_invoker = true) as
select
  credit.id,
  credit.employee_id,
  profile.name as employee_name,
  credit.attendance_record_id,
  credit.source_type,
  credit.source_date,
  credit.granted_minutes,
  coalesce((select sum(allocation.used_minutes) from public.comp_time_usage_allocations allocation where allocation.credit_id = credit.id),0)::integer as used_minutes,
  credit.remaining_minutes,
  credit.expires_on,
  credit.reason,
  credit.granted_at,
  credit.granted_by,
  actor.name as granted_by_name
from public.comp_time_credits credit
join public.profiles profile on profile.id = credit.employee_id
left join public.profiles actor on actor.id = credit.granted_by;
grant select on public.comp_time_credit_details_view to authenticated;

drop view if exists public.comp_time_balances_view;
create view public.comp_time_balances_view with (security_invoker = true) as
select profile.id as employee_id,
  coalesce((select sum(credit.granted_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id),0)::integer as total_granted_comp_time_minutes,
  coalesce((select sum(credit.granted_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id),0)::integer as approved_overtime_minutes,
  coalesce((select sum(allocation.used_minutes) from public.comp_time_usage_allocations allocation join public.comp_time_credits credit on credit.id = allocation.credit_id where credit.employee_id = profile.id),0)::integer as used_comp_time_minutes,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.expires_on >= (now() at time zone 'Asia/Seoul')::date),0)::integer as available_comp_time_minutes,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.expires_on < (now() at time zone 'Asia/Seoul')::date),0)::integer as expired_comp_time_minutes,
  (select min(credit.expires_on) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.remaining_minutes > 0 and credit.expires_on >= (now() at time zone 'Asia/Seoul')::date) as next_expiry_on,
  coalesce((select sum(credit.remaining_minutes) from public.comp_time_credits credit where credit.employee_id = profile.id and credit.remaining_minutes > 0 and credit.expires_on between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 7),0)::integer as expiring_soon_minutes
from public.profiles profile
where profile.is_active and profile.role = 'employee';
grant select on public.comp_time_balances_view to authenticated;

drop view if exists public.monthly_overtime_after_comp_view;
create view public.monthly_overtime_after_comp_view with (security_invoker = true) as
with approved as (
  select record.employee_id,to_char(record.work_date,'YYYY-MM') as source_month,
    sum(record.approved_overtime_minutes)::integer as approved_overtime_minutes
  from public.attendance_records record
  where record.deleted_at is null and record.overtime_status = 'approved'
  group by record.employee_id,to_char(record.work_date,'YYYY-MM')
), used_from_source as (
  select credit.employee_id,to_char(credit.source_date,'YYYY-MM') as source_month,
    sum(allocation.used_minutes)::integer as comp_time_used_from_source_minutes
  from public.comp_time_usage_allocations allocation
  join public.comp_time_credits credit on credit.id = allocation.credit_id
  where credit.source_type = 'overtime'
  group by credit.employee_id,to_char(credit.source_date,'YYYY-MM')
)
select coalesce(approved.employee_id,used_from_source.employee_id) as employee_id,
  coalesce(approved.source_month,used_from_source.source_month) as source_month,
  coalesce(approved.approved_overtime_minutes,0)::integer as approved_overtime_minutes,
  coalesce(used_from_source.comp_time_used_from_source_minutes,0)::integer as comp_time_used_from_source_minutes,
  greatest(0,coalesce(approved.approved_overtime_minutes,0) - coalesce(used_from_source.comp_time_used_from_source_minutes,0))::integer as overtime_after_comp_minutes
from approved
full join used_from_source
  on used_from_source.employee_id = approved.employee_id
 and used_from_source.source_month = approved.source_month;
grant select on public.monthly_overtime_after_comp_view to authenticated;

create or replace function public.admin_save_annual_leave_entitlement(
  p_entitlement_id uuid,
  p_employee_id uuid,
  p_valid_from date,
  p_valid_to date,
  p_base_minutes integer,
  p_carryover_minutes integer,
  p_adjustment_minutes integer,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_id uuid;
  v_before text := '';
  v_after text;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_valid_to < p_valid_from then raise exception 'INVALID_DATE_RANGE'; end if;
  if coalesce(p_base_minutes,0) < 0 or coalesce(p_carryover_minutes,0) < 0
     or (coalesce(p_base_minutes,0) + coalesce(p_carryover_minutes,0) + coalesce(p_adjustment_minutes,0)) < 0
     or coalesce(p_base_minutes,0) % 60 <> 0 or coalesce(p_carryover_minutes,0) % 60 <> 0
     or coalesce(p_adjustment_minutes,0) % 60 <> 0 then raise exception 'INVALID_LEAVE_MINUTES'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.profiles where id = p_employee_id and role = 'employee') then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if exists (
    select 1 from public.annual_leave_entitlements
    where employee_id = p_employee_id
      and deleted_at is null
      and id <> coalesce(p_entitlement_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and valid_from <= p_valid_to and valid_to >= p_valid_from
  ) then raise exception 'ANNUAL_LEAVE_PERIOD_OVERLAP'; end if;

  if p_entitlement_id is null then
    insert into public.annual_leave_entitlements (
      employee_id,valid_from,valid_to,base_minutes,carryover_minutes,
      adjustment_minutes,reason,created_by
    ) values (
      p_employee_id,p_valid_from,p_valid_to,p_base_minutes,p_carryover_minutes,
      p_adjustment_minutes,trim(p_reason),auth.uid()
    ) returning id into v_id;
  else
    select to_jsonb(entitlement)::text into v_before
    from public.annual_leave_entitlements entitlement
    where id = p_entitlement_id and deleted_at is null for update;
    if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
    update public.annual_leave_entitlements
    set employee_id = p_employee_id,valid_from = p_valid_from, valid_to = p_valid_to,
        base_minutes = p_base_minutes, carryover_minutes = p_carryover_minutes,
        adjustment_minutes = p_adjustment_minutes, reason = trim(p_reason), updated_at = now()
    where id = p_entitlement_id returning id into v_id;
  end if;

  select to_jsonb(entitlement)::text into v_after
  from public.annual_leave_entitlements entitlement where id = v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    p_employee_id,'annual_leave_entitlement_saved','annual_leave_balance',
    v_before,v_after,trim(p_reason),auth.uid(),v_role
  );
  return v_id;
end $$;

create or replace function public.admin_delete_annual_leave_entitlement(
  p_entitlement_id uuid,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_entitlement public.annual_leave_entitlements;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_entitlement
  from public.annual_leave_entitlements
  where id = p_entitlement_id and deleted_at is null
  for update;
  if not found then raise exception 'ENTITLEMENT_NOT_FOUND'; end if;
  update public.annual_leave_entitlements
  set deleted_at = now(),deleted_by = auth.uid(),delete_reason = trim(p_reason),updated_at = now()
  where id = p_entitlement_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    v_entitlement.employee_id,'annual_leave_entitlement_deleted','annual_leave_balance',
    to_jsonb(v_entitlement)::text,'삭제 처리',trim(p_reason),auth.uid(),v_role
  );
end $$;

create or replace function public.admin_add_comp_time_credit(
  p_employee_id uuid,
  p_minutes integer,
  p_source_date date,
  p_expires_on date,
  p_source_type text,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_id uuid;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_minutes < 30 or p_minutes % 30 <> 0 then raise exception 'INVALID_COMP_TIME_MINUTES'; end if;
  if p_source_date is null or p_expires_on < p_source_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_source_type not in ('opening_balance','admin_adjustment') then raise exception 'INVALID_SOURCE_TYPE'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  insert into public.comp_time_credits (
    attendance_record_id,employee_id,granted_minutes,remaining_minutes,
    expires_on,granted_by,reason,source_type,source_date
  ) values (
    null,p_employee_id,p_minutes,p_minutes,p_expires_on,auth.uid(),trim(p_reason),p_source_type,p_source_date
  ) returning id into v_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    p_employee_id,'comp_time_credit_added','comp_time_balance','',
    jsonb_build_object('minutes',p_minutes,'source_date',p_source_date,'expires_on',p_expires_on,'source_type',p_source_type)::text,
    trim(p_reason),auth.uid(),v_role
  );
  return v_id;
end $$;

create or replace function public.admin_extend_comp_time_credit(
  p_credit_id uuid,
  p_new_expires_on date,
  p_reason text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_credit public.comp_time_credits;
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_credit from public.comp_time_credits where id = p_credit_id for update;
  if not found then raise exception 'CREDIT_NOT_FOUND'; end if;
  if p_new_expires_on <= v_credit.expires_on then raise exception 'EXPIRY_MUST_EXTEND'; end if;
  update public.comp_time_credits set expires_on = p_new_expires_on where id = p_credit_id;
  insert into public.attendance_audit_logs (
    employee_id,action_type,changed_field,before_value,after_value,
    reason,changed_by,changed_by_role
  ) values (
    v_credit.employee_id,'comp_time_expiry_extended','comp_time_expiry',
    v_credit.expires_on::text,p_new_expires_on::text,trim(p_reason),auth.uid(),v_role
  );
end $$;

create or replace function public.prepare_attendance_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.end_date := coalesce(new.end_date,new.target_date);
  if new.request_type in ('clock_in_at','clock_out_at') then
    new.end_date := new.target_date;
    new.calculated_minutes := 0;
  elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','business_trip','overtime','other_leave') then
    new.calculated_minutes := public.calculate_attendance_request_minutes(
      new.request_type,new.target_date,new.end_date,new.start_time,new.end_time
    );
    if new.calculated_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
    new.requested_value := new.calculated_minutes::text;
  end if;
  if new.request_type in ('special_leave','other_leave')
     and char_length(trim(coalesce(new.request_subtype,''))) < 2 then
    raise exception 'LEAVE_NAME_REQUIRED';
  end if;
  return new;
end $$;

create or replace function public.approved_leave_minutes_during_attendance(
  p_employee_id uuid,
  p_clock_in timestamptz,
  p_clock_out timestamptz
) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(count(*),0)::integer
  from generate_series(
    date_trunc('minute',p_clock_in at time zone 'Asia/Seoul'),
    date_trunc('minute',p_clock_out at time zone 'Asia/Seoul') - interval '1 minute',
    interval '1 minute'
  ) minute_point
  where minute_point::time >= time '09:00'
    and minute_point::time < time '18:00'
    and not (minute_point::time >= time '12:00' and minute_point::time < time '13:00')
    and exists (
      select 1 from public.correction_requests request
      where request.employee_id = p_employee_id
        and request.status = 'approved'
        and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
        and minute_point::date between request.target_date and coalesce(request.end_date,request.target_date)
        and minute_point::time >= case when minute_point::date = request.target_date then coalesce(request.start_time,time '09:00') else time '09:00' end
        and minute_point::time < case when minute_point::date = coalesce(request.end_date,request.target_date) then coalesce(request.end_time,time '18:00') else time '18:00' end
    )
$$;

create or replace function public.validate_leave_balance_before_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_needed integer := 0;
  v_available integer := 0;
  v_entitlement public.annual_leave_entitlements;
begin
  if new.status <> 'approved' or new.request_type not in ('annual_leave','comp_time') then return new; end if;
  v_needed := greatest(0,coalesce(nullif(new.approved_minutes,0),new.calculated_minutes));
  if v_needed <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;

  if new.request_type = 'annual_leave' then
    select * into v_entitlement
    from public.annual_leave_entitlements
    where employee_id = new.employee_id
      and deleted_at is null
      and valid_from <= new.target_date
      and valid_to >= coalesce(new.end_date,new.target_date)
    order by valid_to limit 1 for update;
    if not found then raise exception 'ANNUAL_LEAVE_ENTITLEMENT_REQUIRED'; end if;
    select (
      v_entitlement.base_minutes + v_entitlement.carryover_minutes + v_entitlement.adjustment_minutes
      - coalesce(sum(coalesce(nullif(request.approved_minutes,0),request.calculated_minutes)),0)
    )::integer into v_available
    from public.correction_requests request
    where request.employee_id = new.employee_id
      and request.request_type = 'annual_leave'
      and request.status = 'approved'
      and request.id <> new.id
      and request.target_date >= v_entitlement.valid_from
      and coalesce(request.end_date,request.target_date) <= v_entitlement.valid_to;
    if v_available < v_needed then raise exception 'ANNUAL_LEAVE_BALANCE_INSUFFICIENT:%',v_available; end if;
  else
    select coalesce(sum(credit.remaining_minutes),0)::integer into v_available
    from public.comp_time_credits credit
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.source_date < new.target_date
      and credit.expires_on >= new.target_date;
    if v_available < v_needed then raise exception 'COMP_TIME_BALANCE_INSUFFICIENT:%',v_available; end if;
  end if;
  return new;
end $$;

drop trigger if exists validate_leave_balance_before_approval_trigger on public.correction_requests;
create trigger validate_leave_balance_before_approval_trigger
before insert or update of status,request_type,target_date,end_date,calculated_minutes,approved_minutes
on public.correction_requests
for each row execute function public.validate_leave_balance_before_approval();

create or replace function public.allocate_comp_time_usage_without_negative()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_allocation record;
  v_credit record;
  v_needed integer := 0;
  v_use integer := 0;
begin
  for v_allocation in select credit_id,used_minutes from public.comp_time_usage_allocations where correction_request_id = new.id loop
    update public.comp_time_credits
    set remaining_minutes = least(granted_minutes,remaining_minutes + v_allocation.used_minutes)
    where id = v_allocation.credit_id;
  end loop;
  delete from public.comp_time_usage_allocations where correction_request_id = new.id;
  if new.status <> 'approved' or new.request_type <> 'comp_time' then return new; end if;
  v_needed := greatest(0,coalesce(nullif(new.approved_minutes,0),new.calculated_minutes));
  for v_credit in
    select credit.* from public.comp_time_credits credit
    where credit.employee_id = new.employee_id
      and credit.remaining_minutes > 0
      and credit.source_date < new.target_date
      and credit.expires_on >= new.target_date
    order by credit.expires_on,credit.source_date,credit.granted_at
    for update
  loop
    exit when v_needed <= 0;
    v_use := least(v_needed,v_credit.remaining_minutes);
    update public.comp_time_credits set remaining_minutes = remaining_minutes - v_use where id = v_credit.id;
    insert into public.comp_time_usage_allocations (correction_request_id,credit_id,used_minutes)
    values (new.id,v_credit.id,v_use);
    v_needed := v_needed - v_use;
  end loop;
  if v_needed > 0 then raise exception 'COMP_TIME_BALANCE_INSUFFICIENT:%',v_needed; end if;
  return new;
end $$;

drop trigger if exists allocate_comp_time_usage_without_negative_trigger on public.correction_requests;
create trigger allocate_comp_time_usage_without_negative_trigger
after insert or update of status,request_type,approved_minutes,calculated_minutes,requested_value
on public.correction_requests
for each row execute function public.allocate_comp_time_usage_without_negative();

-- 이전 설치 순서 때문에 승인됐지만 적립원장과 연결되지 않은 대체휴무를 가능한 범위에서 다시 연결합니다.
do $$
declare
  v_request record;
begin
  for v_request in
    select request.id
    from public.correction_requests request
    where request.request_type = 'comp_time'
      and request.status = 'approved'
      and not exists (
        select 1 from public.comp_time_usage_allocations allocation
        where allocation.correction_request_id = request.id
      )
    order by request.target_date,request.requested_at
  loop
    begin
      update public.correction_requests
      set approved_minutes = approved_minutes
      where id = v_request.id;
    exception when others then
      null;
    end;
  end loop;
end $$;

create or replace function public.sync_approved_request_to_attendance_exception()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_default_start time := coalesce((select default_start_time from public.organization_settings where id = true),time '09:00');
  v_default_end time := coalesce((select default_end_time from public.organization_settings where id = true),time '18:00');
  v_end_date date := coalesce(new.end_date,new.target_date);
  v_exception_type text;
  v_should_create boolean := false;
begin
  if coalesce(new.before_value,'') = '관리자 직접 등록' then return new; end if;
  if new.status = 'approved' then
    if new.request_type = 'business_trip' then v_exception_type := 'business_trip'; v_should_create := true;
    elsif new.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and coalesce(new.start_time,v_default_start) <= v_default_start
      and coalesce(new.end_time,v_default_end) >= v_default_end then
      v_exception_type := new.request_type; v_should_create := true;
    end if;
  end if;
  if v_should_create then
    if not exists (select 1 from public.attendance_exceptions where correction_request_id = new.id and cancelled_at is null)
       and not exists (select 1 from public.attendance_exceptions where employee_id = new.employee_id and cancelled_at is null and start_date <= v_end_date and end_date >= new.target_date) then
      insert into public.attendance_exceptions (
        employee_id,start_date,end_date,exception_type,reason,approved_by,approved_at,correction_request_id
      ) values (
        new.employee_id,new.target_date,v_end_date,v_exception_type,
        case when new.request_type in ('special_leave','other_leave') then trim(new.request_subtype) || ': ' || trim(new.reason) else trim(new.reason) end,
        coalesce(new.reviewer_id,auth.uid()),coalesce(new.reviewed_at,now()),new.id
      );
    end if;
  else
    update public.attendance_exceptions
    set cancelled_at = coalesce(cancelled_at,now()),cancelled_by = coalesce(cancelled_by,auth.uid()),
        cancellation_reason = case when cancellation_reason = '' then '연결된 신청의 승인 상태 변경' else cancellation_reason end
    where correction_request_id = new.id and cancelled_at is null;
  end if;
  return new;
end $$;

create or replace function public.recalculate_attendance_after_leave_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then return new; end if;
  if tg_op = 'UPDATE' and old.status is not distinct from new.status
     and old.target_date is not distinct from new.target_date
     and old.end_date is not distinct from new.end_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time then return new; end if;
  update public.comp_time_credits credit
  set remaining_minutes = 0,reason = trim(concat_ws(E'\n',credit.reason,'휴가 반영으로 실제 근무시간 재검토'))
  where credit.attendance_record_id in (
    select record.id from public.attendance_records record
    where record.employee_id = new.employee_id
      and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
      and record.deleted_at is null
  ) and credit.remaining_minutes > 0;
  update public.attendance_records record
  set overtime_status = 'pending',approved_overtime_minutes = 0,comp_time_eligible_minutes = 0,
      clock_out_at = record.clock_out_at,changed = true,updated_at = now()
  where record.employee_id = new.employee_id
    and record.work_date between new.target_date and coalesce(new.end_date,new.target_date)
    and record.deleted_at is null and record.clock_in_at is not null and record.clock_out_at is not null;
  return new;
end $$;

-- 외부교육은 예외 메모가 아니라 날짜별 09:00부터 18:00까지의 근무기록으로 만듭니다.
-- 같은 날짜에 이미 근태기록이 있으면 기존 기록을 덮어쓰지 않고 건너뜁니다.
create or replace function public.admin_create_attendance_exceptions(
  p_employee_ids uuid[],
  p_start_date date,
  p_end_date date,
  p_exception_type text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.current_profile_role();
  v_employee_id uuid;
  v_employee_name text;
  v_work_date date;
  v_record_id uuid;
  v_created integer := 0;
  v_skipped_names text[] := array[]::text[];
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if coalesce(array_length(p_employee_ids,1),0) = 0 then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if p_end_date < p_start_date then raise exception 'INVALID_DATE_RANGE'; end if;
  if p_exception_type not in ('business_trip','external_training','approved_other','annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_EXCEPTION_TYPE'; end if;
  if p_exception_type in ('external_training','special_leave','other_leave') and char_length(trim(coalesce(p_reason,''))) < 2 then raise exception 'REASON_REQUIRED'; end if;

  foreach v_employee_id in array p_employee_ids loop
    select name into v_employee_name from public.profiles
    where id = v_employee_id and role = 'employee' and is_active = true;
    if not found then
      v_skipped_names := array_append(v_skipped_names,'비활성 또는 미확인 직원');
      continue;
    end if;

    if p_exception_type = 'external_training' then
      for v_work_date in select generate_series(p_start_date,p_end_date,interval '1 day')::date loop
        if exists (select 1 from public.attendance_records where employee_id = v_employee_id and work_date = v_work_date and deleted_at is null) then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_records (
          employee_id,work_date,work_type,clock_in_at,clock_out_at,
          clock_in_location_status,clock_out_location_status,attendance_status,note,changed
        ) values (
          v_employee_id,v_work_date,'education',
          (v_work_date + time '09:00') at time zone 'Asia/Seoul',
          (v_work_date + time '18:00') at time zone 'Asia/Seoul',
          'not_checked','not_checked','normal','',true
        )
        on conflict (employee_id,work_date) do update
        set work_type = 'education',
            clock_in_at = excluded.clock_in_at,
            clock_out_at = excluded.clock_out_at,
            clock_in_location_status = 'not_checked',
            clock_out_location_status = 'not_checked',
            attendance_status = 'normal',
            note = '',
            changed = true,
            deleted_at = null,
            updated_at = now()
        where attendance_records.deleted_at is not null
        returning id into v_record_id;
        if v_record_id is null then
          v_skipped_names := array_append(v_skipped_names,v_employee_name || ' ' || v_work_date::text);
          continue;
        end if;
        insert into public.attendance_audit_logs (
          attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,
          reason,changed_by,changed_by_role
        ) values (
          v_record_id,v_employee_id,'external_training_record_create','attendance_record','',
          jsonb_build_object('work_date',v_work_date,'clock_in_time','09:00','clock_out_time','18:00')::text,
          trim(coalesce(p_reason,'')),auth.uid(),v_role
        );
        v_created := v_created + 1;
      end loop;
    elsif exists (
      select 1 from public.attendance_exceptions
      where employee_id = v_employee_id and cancelled_at is null
        and start_date <= p_end_date and end_date >= p_start_date
    ) then
      v_skipped_names := array_append(v_skipped_names,v_employee_name);
    else
      perform public.admin_create_attendance_exception(v_employee_id,p_start_date,p_end_date,p_exception_type,p_reason);
      v_created := v_created + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'created_count',v_created,
    'skipped_count',coalesce(array_length(v_skipped_names,1),0),
    'skipped_names',to_jsonb(v_skipped_names)
  );
end $$;

-- 관리자 확인 화면에서 특별휴가도 기존 근태기록에 직접 반영할 수 있게 합니다.
create or replace function public.admin_apply_leave_to_attendance_record(
  p_record_id uuid,
  p_request_type text,
  p_start_time time,
  p_end_time time,
  p_request_subtype text,
  p_comment text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_record public.attendance_records;
  v_role text := public.current_profile_role();
  v_request_id uuid;
  v_minutes integer;
  v_leave_type text := 'none';
begin
  if v_role not in ('admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_request_type not in ('annual_leave','comp_time','special_leave','sick_leave','other_leave') then raise exception 'INVALID_LEAVE_TYPE'; end if;
  if char_length(trim(coalesce(p_comment,''))) < 5 then raise exception 'COMMENT_REQUIRED'; end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then raise exception 'INVALID_TIME_RANGE'; end if;
  if p_request_type in ('special_leave','other_leave') and char_length(trim(coalesce(p_request_subtype,''))) < 2 then raise exception 'LEAVE_NAME_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id = p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if exists (select 1 from public.monthly_closings where year = extract(year from v_record.work_date) and month = extract(month from v_record.work_date) and status = 'closed') and v_role <> 'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  v_minutes := public.calculate_attendance_request_minutes(p_request_type,v_record.work_date,v_record.work_date,p_start_time,p_end_time);
  if v_minutes <= 0 then raise exception 'REQUEST_TIME_ZERO'; end if;
  insert into public.correction_requests (
    attendance_record_id,employee_id,target_date,end_date,start_time,end_time,calculated_minutes,approved_minutes,
    request_type,request_subtype,before_value,requested_value,reason,status,reviewer_id,reviewer_comment,reviewed_at
  ) values (
    v_record.id,v_record.employee_id,v_record.work_date,v_record.work_date,p_start_time,p_end_time,v_minutes,v_minutes,
    p_request_type,case when p_request_type in ('special_leave','other_leave') then trim(coalesce(p_request_subtype,'')) else '' end,
    v_record.attendance_status,v_minutes::text,trim(p_comment),'approved',auth.uid(),trim(p_comment),now()
  ) returning id into v_request_id;
  if p_request_type = 'annual_leave' then
    v_leave_type := case v_minutes when 480 then 'annual_leave' when 240 then 'half_day' when 120 then 'quarter_day' when 60 then 'hourly_leave' else 'none' end;
  elsif p_request_type = 'sick_leave' then v_leave_type := 'sick_leave';
  end if;
  update public.attendance_records set attendance_status = case when clock_out_at is null then 'working' else 'normal' end,leave_type = v_leave_type,changed = true,updated_at = now() where id = v_record.id;
  insert into public.attendance_audit_logs (
    attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,correction_request_id
  ) values (
    v_record.id,v_record.employee_id,'admin_leave_applied','leave_request',v_record.attendance_status,
    jsonb_build_object('request_type',p_request_type,'start_time',p_start_time,'end_time',p_end_time,'minutes',v_minutes,'subtype',trim(coalesce(p_request_subtype,'')))::text,
    trim(p_comment),auth.uid(),v_role,v_request_id
  );
  return v_request_id;
end $$;

-- 기존 외부교육 예외 일정도 같은 기준으로 전환합니다.
insert into public.attendance_records (
  employee_id,work_date,work_type,clock_in_at,clock_out_at,
  clock_in_location_status,clock_out_location_status,attendance_status,note,changed
)
select distinct on (exception.employee_id,day_value::date)
  exception.employee_id,day_value::date,'education',
  (day_value::date + time '09:00') at time zone 'Asia/Seoul',
  (day_value::date + time '18:00') at time zone 'Asia/Seoul',
  'not_checked','not_checked','normal','',true
from public.attendance_exceptions exception
cross join lateral generate_series(exception.start_date,exception.end_date,interval '1 day') day_value
where exception.exception_type = 'external_training'
  and exception.cancelled_at is null
order by exception.employee_id,day_value::date,exception.approved_at desc
on conflict (employee_id,work_date) do update
set work_type = 'education',
    clock_in_at = excluded.clock_in_at,
    clock_out_at = excluded.clock_out_at,
    clock_in_location_status = 'not_checked',
    clock_out_location_status = 'not_checked',
    attendance_status = 'normal',
    note = '',
    changed = true,
    deleted_at = null,
    updated_at = now()
where attendance_records.deleted_at is not null;

update public.attendance_exceptions
set cancelled_at = now(),cancelled_by = coalesce(cancelled_by,approved_by),
    cancellation_reason = case when cancellation_reason = '' then '외부교육을 09:00부터 18:00까지의 근무기록으로 전환' else cancellation_reason end
where exception_type = 'external_training' and cancelled_at is null;

revoke all on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) from public,anon;
grant execute on function public.admin_save_annual_leave_entitlement(uuid,uuid,date,date,integer,integer,integer,text) to authenticated;
revoke all on function public.admin_delete_annual_leave_entitlement(uuid,text) from public,anon;
grant execute on function public.admin_delete_annual_leave_entitlement(uuid,text) to authenticated;
revoke all on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) from public,anon;
grant execute on function public.admin_add_comp_time_credit(uuid,integer,date,date,text,text) to authenticated;
revoke all on function public.admin_extend_comp_time_credit(uuid,date,text) from public,anon;
grant execute on function public.admin_extend_comp_time_credit(uuid,date,text) to authenticated;
revoke all on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) from public,anon;
grant execute on function public.admin_create_attendance_exceptions(uuid[],date,date,text,text) to authenticated;
revoke all on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) from public,anon;
grant execute on function public.admin_apply_leave_to_attendance_record(uuid,text,time,time,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;

select '연차와 대체휴무 잔액, 특별휴가 보완 완료' as result;
