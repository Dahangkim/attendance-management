begin;

alter table public.correction_requests
  add column if not exists overtime_approval_limit_minutes integer not null default 0,
  add column if not exists comp_time_approval_limit_minutes integer not null default 0,
  add column if not exists overtime_finalized_at timestamptz;

create or replace function public.finalize_preapproved_overtime(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_request public.correction_requests;
  v_record public.attendance_records;
  v_overtime integer := 0;
  v_comp integer := 0;
  v_used integer := 0;
begin
  select * into v_request from public.correction_requests
  where id=p_request_id and request_type='overtime' and status='approved' for update;
  if not found then return; end if;

  select * into v_record from public.attendance_records
  where org_id=v_request.org_id and employee_id=v_request.employee_id
    and work_date=v_request.target_date and deleted_at is null for update;
  if not found or v_record.clock_out_at is null then return; end if;

  v_overtime := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.overtime_approval_limit_minutes);
  v_comp := least(coalesce(v_record.recorded_overtime_minutes,0),v_request.comp_time_approval_limit_minutes);

  update public.correction_requests set attendance_record_id=v_record.id,
    approved_minutes=v_overtime,overtime_finalized_at=now() where id=v_request.id;
  update public.attendance_records set overtime_status='approved',
    approved_overtime_minutes=v_overtime,comp_time_eligible_minutes=v_comp,
    changed=true,updated_at=now() where id=v_record.id;

  if v_comp > 0 then
    insert into public.comp_time_credits(org_id,attendance_record_id,employee_id,source_type,source_date,
      granted_minutes,remaining_minutes,expires_on,granted_by,reason)
    values(v_request.org_id,v_record.id,v_request.employee_id,'overtime',v_record.work_date,
      v_comp,v_comp,v_record.work_date+30,
      v_request.reviewer_id,coalesce(nullif(trim(v_request.reviewer_comment),''),v_request.reason))
    on conflict(attendance_record_id) do update set
      org_id=excluded.org_id,employee_id=excluded.employee_id,
      source_type=excluded.source_type,source_date=excluded.source_date,
      granted_minutes=excluded.granted_minutes,
      remaining_minutes=greatest(0,excluded.granted_minutes-(public.comp_time_credits.granted_minutes-public.comp_time_credits.remaining_minutes)),
      expires_on=excluded.expires_on,granted_by=excluded.granted_by,granted_at=now(),reason=excluded.reason;
  else
    select coalesce(granted_minutes-remaining_minutes,0) into v_used
    from public.comp_time_credits where attendance_record_id=v_record.id;
    if v_used > 0 then raise exception 'COMP_TIME_ALREADY_USED'; end if;
    delete from public.comp_time_credits where attendance_record_id=v_record.id;
  end if;
end $$;

create or replace function public.review_overtime_request_in_advance(
  p_request_id uuid,p_decision text,p_overtime_limit_minutes integer,
  p_comp_time_limit_minutes integer,p_comment text
) returns void language plpgsql security definer set search_path=public as $$
declare
  v_request public.correction_requests;
  v_role text:=public.current_profile_role();
  v_org_id uuid:=public.current_profile_org_id();
  v_week_start date;
  v_week_total integer:=0;
begin
  if v_role not in ('admin','org_admin','super_admin') then raise exception 'ADMIN_REQUIRED'; end if;
  if p_decision not in ('approved','rejected','more_info') then raise exception 'INVALID_DECISION'; end if;
  if p_decision<>'approved' and char_length(trim(coalesce(p_comment,'')))<2 then raise exception 'COMMENT_REQUIRED'; end if;
  select * into v_request from public.correction_requests where id=p_request_id for update;
  if not found or v_request.request_type<>'overtime' or v_request.status not in ('pending','more_info') then raise exception 'REQUEST_NOT_REVIEWABLE'; end if;
  if v_role<>'super_admin' and v_request.org_id is distinct from v_org_id then raise exception 'ORGANIZATION_ACCESS_DENIED'; end if;
  if exists(select 1 from public.monthly_closings c where c.org_id=v_request.org_id
    and c.year=extract(year from v_request.target_date) and c.month=extract(month from v_request.target_date)
    and c.status='closed') and v_role<>'super_admin' then raise exception 'MONTH_CLOSED'; end if;

  if p_decision='approved' then
    if p_overtime_limit_minutes<0 or p_overtime_limit_minutes>least(240,v_request.calculated_minutes)
      or (p_overtime_limit_minutes>0 and (p_overtime_limit_minutes<60 or p_overtime_limit_minutes%30<>0)) then raise exception 'INVALID_OVERTIME_LIMIT'; end if;
    if p_comp_time_limit_minutes<0 or p_comp_time_limit_minutes>least(240,v_request.calculated_minutes)
      or (p_comp_time_limit_minutes>0 and (p_comp_time_limit_minutes<60 or p_comp_time_limit_minutes%30<>0)) then raise exception 'INVALID_COMP_TIME_LIMIT'; end if;
    v_week_start:=date_trunc('week',v_request.target_date::timestamp)::date;
    select coalesce(sum(coalesce(nullif(r.overtime_approval_limit_minutes,0),r.approved_minutes)),0)::integer into v_week_total
    from public.correction_requests r where r.employee_id=v_request.employee_id and r.id<>v_request.id
      and r.request_type='overtime' and r.status='approved' and r.target_date between v_week_start and v_week_start+6;
    select v_week_total+coalesce(sum(a.approved_overtime_minutes),0)::integer into v_week_total
    from public.attendance_records a where a.employee_id=v_request.employee_id and a.deleted_at is null
      and a.overtime_status='approved' and a.work_date between v_week_start and v_week_start+6
      and not exists(select 1 from public.correction_requests r where r.attendance_record_id=a.id
        and r.request_type='overtime' and r.status='approved');
    select v_week_total+coalesce(sum(r.approved_minutes),0)::integer into v_week_total
    from public.correction_requests r where r.employee_id=v_request.employee_id
      and r.request_type='emergency_support' and r.status='approved' and r.target_date between v_week_start and v_week_start+6;
    v_week_total:=v_week_total+p_overtime_limit_minutes;
    perform public.consume_weekly_overtime_override(v_request.employee_id,v_request.target_date,v_week_total,'overtime',v_request.id);
  end if;

  update public.correction_requests set status=p_decision,reviewer_id=auth.uid(),
    reviewer_comment=coalesce(p_comment,''),reviewed_at=now(),approved_minutes=0,
    overtime_approval_limit_minutes=case when p_decision='approved' then p_overtime_limit_minutes else 0 end,
    comp_time_approval_limit_minutes=case when p_decision='approved' then p_comp_time_limit_minutes else 0 end,
    overtime_finalized_at=null where id=p_request_id;

  insert into public.attendance_audit_logs(attendance_record_id,employee_id,action_type,changed_field,
    before_value,after_value,reason,changed_by,changed_by_role,correction_request_id,org_id)
  values(v_request.attendance_record_id,v_request.employee_id,
    case when p_decision='approved' then 'request_approved' else 'correction_review' end,'overtime',
    v_request.status,jsonb_build_object('status',p_decision,'overtime_limit_minutes',p_overtime_limit_minutes,
      'comp_time_limit_minutes',p_comp_time_limit_minutes)::text,
    coalesce(nullif(trim(p_comment),''),v_request.reason),auth.uid(),v_role,v_request.id,v_request.org_id);

  if p_decision='approved' then perform public.finalize_preapproved_overtime(p_request_id); end if;
end $$;

create or replace function public.sync_overtime_request_to_attendance()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_used integer:=0;
begin
  if new.request_type<>'overtime' then return new; end if;
  if new.status='approved' then perform public.finalize_preapproved_overtime(new.id);
  elsif tg_op='UPDATE' and old.status='approved' and new.status<>'approved' then
    select coalesce(granted_minutes-remaining_minutes,0) into v_used
    from public.comp_time_credits where attendance_record_id=old.attendance_record_id;
    if v_used>0 then raise exception 'COMP_TIME_ALREADY_USED'; end if;
    delete from public.comp_time_credits where attendance_record_id=old.attendance_record_id;
    update public.attendance_records set overtime_status=case when recorded_overtime_minutes>0 then 'pending' else 'none' end,
      approved_overtime_minutes=0,comp_time_eligible_minutes=0,changed=true,updated_at=now()
    where employee_id=new.employee_id and work_date=new.target_date and deleted_at is null;
  end if;
  return new;
end $$;

create or replace function public.finalize_preapproved_overtime_after_clock_out()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if new.clock_out_at is null then return new; end if;
  select id into v_id from public.correction_requests where org_id=new.org_id
    and employee_id=new.employee_id and target_date=new.work_date
    and request_type='overtime' and status='approved' order by reviewed_at desc nulls last limit 1;
  if v_id is not null then perform public.finalize_preapproved_overtime(v_id); end if;
  return new;
end $$;

create or replace function public.enforce_weekly_override_on_overtime_approval()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_week_start date; v_total integer;
begin
  if new.overtime_status<>'approved'
     or (tg_op='UPDATE' and old.overtime_status='approved' and old.approved_overtime_minutes=new.approved_overtime_minutes) then return new; end if;
  if exists(select 1 from public.correction_requests r where r.attendance_record_id=new.id
    and r.request_type='overtime' and r.status='approved' and r.overtime_approval_limit_minutes>0) then return new; end if;
  v_week_start:=date_trunc('week',new.work_date::timestamp)::date;
  select coalesce(sum(approved_overtime_minutes),0)::integer into v_total from public.attendance_records
  where employee_id=new.employee_id and id<>new.id and deleted_at is null and overtime_status='approved'
    and work_date between v_week_start and v_week_start+6;
  select v_total+coalesce(sum(approved_minutes),0)::integer into v_total from public.correction_requests
  where employee_id=new.employee_id and request_type='emergency_support' and status='approved'
    and target_date between v_week_start and v_week_start+6;
  v_total:=v_total+coalesce(new.approved_overtime_minutes,0);
  perform public.consume_weekly_overtime_override(new.employee_id,new.work_date,v_total,'overtime',new.id);
  return new;
end $$;

drop trigger if exists finalize_preapproved_overtime_after_clock_out_trigger on public.attendance_records;
create trigger finalize_preapproved_overtime_after_clock_out_trigger
after insert or update of clock_out_at,recorded_overtime_minutes on public.attendance_records
for each row execute function public.finalize_preapproved_overtime_after_clock_out();

revoke all on function public.review_overtime_request_in_advance(uuid,text,integer,integer,text) from public,anon;
grant execute on function public.review_overtime_request_in_advance(uuid,text,integer,integer,text) to authenticated;
revoke all on function public.finalize_preapproved_overtime(uuid) from public,anon;
revoke all on function public.finalize_preapproved_overtime_after_clock_out() from public,anon;
notify pgrst,'reload schema';
commit;

select '시간외근무와 대휴 사전승인 한도 및 퇴근 확정 보완 완료' as result;
