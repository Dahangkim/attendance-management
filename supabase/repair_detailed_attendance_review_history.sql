begin;

alter table public.attendance_records
  add column if not exists clock_in_reviewed_at timestamptz,
  add column if not exists clock_in_reviewed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists clock_out_reviewed_at timestamptz,
  add column if not exists clock_out_reviewed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists work_time_reviewed_at timestamptz,
  add column if not exists work_time_reviewed_by uuid references public.profiles(id) on delete restrict;

create or replace function public.derive_attendance_status(p_record public.attendance_records)
returns text language plpgsql stable security definer set search_path=public as $$
declare
  v_settings public.organization_settings;
  v_is_regular_workday boolean;
  v_expected_start time;
  v_elapsed_minutes integer;
  v_worked_minutes integer;
  v_approved_leave_minutes integer:=0;
  v_required_minutes integer:=480;
  v_leave_type text:='none';
begin
  select * into v_settings from public.organization_settings where org_id=p_record.org_id;
  if not found then raise exception 'ORGANIZATION_SETTINGS_REQUIRED'; end if;
  v_leave_type:=coalesce(to_jsonb(p_record)->>'leave_type','none');
  if p_record.clock_in_at is null then return case
    when v_leave_type in ('annual_leave','half_day','quarter_day','hourly_leave','sick_leave') then v_leave_type
    when p_record.attendance_status in ('business_trip','leave') then p_record.attendance_status else 'missing_in' end; end if;
  v_is_regular_workday:=extract(isodow from p_record.work_date)::smallint=any(v_settings.work_days)
    and not exists(select 1 from public.organization_holidays where org_id=p_record.org_id and holiday_date=p_record.work_date and is_paid_holiday);
  if p_record.clock_in_location_status in ('outside','low_accuracy','permission_denied','unavailable')
     and not coalesce(p_record.clock_in_ip_matched,false) and p_record.clock_in_reviewed_at is null then return 'admin_review'; end if;
  if p_record.clock_out_at is not null and p_record.clock_out_location_status in ('outside','low_accuracy','permission_denied','unavailable')
     and not coalesce(p_record.clock_out_ip_matched,false) and p_record.clock_out_reviewed_at is null then return 'admin_review'; end if;
  if not v_is_regular_workday then return 'holiday_work'; end if;

  select coalesce(count(*),0)::integer into v_approved_leave_minutes
  from generate_series(p_record.work_date+v_settings.default_start_time,p_record.work_date+v_settings.default_end_time-interval '1 minute',interval '1 minute') minute_point
  where not(minute_point::time>=time '12:00' and minute_point::time<time '13:00') and exists(
    select 1 from public.correction_requests request where request.org_id=p_record.org_id and request.employee_id=p_record.employee_id
      and request.status='approved' and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
      and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
      and minute_point::time>=case when p_record.work_date=request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end
      and minute_point::time<case when p_record.work_date=coalesce(request.end_date,request.target_date) then coalesce(request.end_time,v_settings.default_end_time) else v_settings.default_end_time end);
  v_expected_start:=v_settings.default_start_time;
  select greatest(v_expected_start,coalesce(max(case when p_record.work_date=coalesce(request.end_date,request.target_date)
    then coalesce(request.end_time,v_settings.default_end_time) else v_settings.default_end_time end),v_expected_start)) into v_expected_start
  from public.correction_requests request where request.org_id=p_record.org_id and request.employee_id=p_record.employee_id
    and request.status='approved' and request.request_type in ('annual_leave','comp_time','special_leave','sick_leave','other_leave')
    and p_record.work_date between request.target_date and coalesce(request.end_date,request.target_date)
    and (case when p_record.work_date=request.target_date then coalesce(request.start_time,v_settings.default_start_time) else v_settings.default_start_time end)<=v_settings.default_start_time;
  if (p_record.clock_in_at at time zone 'Asia/Seoul')::time>v_expected_start+make_interval(mins=>v_settings.late_grace_minutes)
     and p_record.work_time_reviewed_at is null then return 'late'; end if;
  if p_record.clock_out_at is null then return 'working'; end if;
  v_required_minutes:=greatest(0,480-v_approved_leave_minutes);
  v_elapsed_minutes:=greatest(0,floor(extract(epoch from(p_record.clock_out_at-p_record.clock_in_at))/60)::integer);
  v_worked_minutes:=greatest(0,v_elapsed_minutes-case when (p_record.clock_in_at at time zone 'Asia/Seoul')::time<time '13:00'
    and (p_record.clock_out_at at time zone 'Asia/Seoul')::time>time '12:00' then least(60,floor(extract(epoch from(
      least(p_record.clock_out_at,(p_record.work_date+time '13:00') at time zone 'Asia/Seoul')-
      greatest(p_record.clock_in_at,(p_record.work_date+time '12:00') at time zone 'Asia/Seoul')))/60)::integer) else 0 end);
  return case when v_worked_minutes<v_required_minutes and p_record.work_time_reviewed_at is null then 'admin_review' else 'normal' end;
end $$;

create or replace function public.recalculate_attendance_status_on_time_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.clock_in_at is distinct from new.clock_in_at then
    new.clock_in_reviewed_at:=null; new.clock_in_reviewed_by:=null;
    new.work_time_reviewed_at:=null; new.work_time_reviewed_by:=null;
  end if;
  if old.clock_out_at is distinct from new.clock_out_at then
    new.clock_out_reviewed_at:=null; new.clock_out_reviewed_by:=null;
    new.work_time_reviewed_at:=null; new.work_time_reviewed_by:=null;
  end if;
  new.attendance_status:=public.derive_attendance_status(new);
  return new;
end $$;

create or replace function public.admin_confirm_attendance_record(p_record_id uuid,p_comment text)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_record public.attendance_records;
  v_role text:=public.current_profile_role();
  v_org_id uuid:=public.current_profile_org_id();
  v_items text[]:=array[]::text[];
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_comment,'')))<2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_record from public.attendance_records where id=p_record_id and deleted_at is null for update;
  if not found then raise exception 'RECORD_NOT_FOUND'; end if;
  if v_role<>'super_admin' and v_record.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if v_record.is_closed and v_role<>'super_admin' then raise exception 'MONTH_CLOSED'; end if;
  if v_record.attendance_status not in ('admin_review','location_review','field','education','late') then raise exception 'RECORD_NOT_REVIEWABLE'; end if;
  if v_record.clock_in_location_status in ('outside','low_accuracy','permission_denied','unavailable') and not coalesce(v_record.clock_in_ip_matched,false) then
    v_items:=array_append(v_items,'직출 또는 출근 위치'); end if;
  if v_record.clock_out_at is not null and v_record.clock_out_location_status in ('outside','low_accuracy','permission_denied','unavailable') and not coalesce(v_record.clock_out_ip_matched,false) then
    v_items:=array_append(v_items,'직퇴 또는 퇴근 위치'); end if;
  if v_record.attendance_status in ('admin_review','late') and cardinality(v_items)=0 then v_items:=array_append(v_items,'지각 또는 근무시간'); end if;
  update public.attendance_records set
    clock_in_reviewed_at=case when '직출 또는 출근 위치'=any(v_items) then now() else clock_in_reviewed_at end,
    clock_in_reviewed_by=case when '직출 또는 출근 위치'=any(v_items) then auth.uid() else clock_in_reviewed_by end,
    clock_out_reviewed_at=case when '직퇴 또는 퇴근 위치'=any(v_items) then now() else clock_out_reviewed_at end,
    clock_out_reviewed_by=case when '직퇴 또는 퇴근 위치'=any(v_items) then auth.uid() else clock_out_reviewed_by end,
    work_time_reviewed_at=case when '지각 또는 근무시간'=any(v_items) then now() else work_time_reviewed_at end,
    work_time_reviewed_by=case when '지각 또는 근무시간'=any(v_items) then auth.uid() else work_time_reviewed_by end,
    changed=true,updated_at=now() where id=p_record_id;
  update public.attendance_records record set attendance_status=public.derive_attendance_status(record) where id=p_record_id;
  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,before_value,after_value,reason,changed_by,changed_by_role,org_id)
  values(v_record.id,v_record.employee_id,'admin_review_completed','attendance_review',v_record.attendance_status,
    jsonb_build_object('status',(select attendance_status from public.attendance_records where id=p_record_id),'confirmed_items',v_items)::text,
    trim(p_comment),auth.uid(),v_role,v_record.org_id);
end $$;

revoke all on function public.admin_confirm_attendance_record(uuid,text) from public,anon;
grant execute on function public.admin_confirm_attendance_record(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;

select '관리자 확인 항목 분리와 변경이력 상세화 완료' as result;
