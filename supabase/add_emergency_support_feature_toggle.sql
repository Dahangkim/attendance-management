begin;

alter table public.organization_settings
  add column if not exists emergency_support_enabled boolean not null default true;

create or replace function public.enforce_emergency_support_feature_toggle()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_enabled boolean;
begin
  if new.request_type <> 'emergency_support' then
    return new;
  end if;

  select coalesce(settings.emergency_support_enabled, true) into v_enabled
  from public.profiles profile
  left join public.organization_settings settings on settings.org_id = profile.org_id
  where profile.id = new.employee_id;

  if coalesce(v_enabled, true) = false then
    raise exception 'EMERGENCY_SUPPORT_DISABLED';
  end if;
  return new;
end $$;

drop trigger if exists enforce_emergency_support_feature_toggle on public.correction_requests;
create trigger enforce_emergency_support_feature_toggle
before insert on public.correction_requests
for each row execute function public.enforce_emergency_support_feature_toggle();

create or replace function public.save_organization_settings(
  p_default_start_time time,
  p_default_end_time time,
  p_break_minutes integer,
  p_late_grace_minutes integer,
  p_early_leave_grace_minutes integer,
  p_office_ip_address text,
  p_emergency_support_enabled boolean
) returns public.organization_settings
language plpgsql security definer set search_path = public as $$
declare
  v_org_id uuid := public.current_profile_org_id();
  v_role text := public.current_profile_role();
  v_existing_ip text;
  v_settings public.organization_settings;
begin
  if v_org_id is null or v_role not in ('admin','org_admin') then
    raise exception 'ORG_ADMIN_REQUIRED';
  end if;

  select office_ip_address into v_existing_ip
  from public.organization_settings
  where org_id = v_org_id;

  if trim(coalesce(p_office_ip_address,'')) <> trim(coalesce(v_existing_ip,'')) then
    raise exception 'IP_CHANGE_APPROVAL_REQUIRED';
  end if;

  insert into public.organization_settings (
    id, org_id, default_start_time, default_end_time, break_minutes,
    late_grace_minutes, early_leave_grace_minutes, office_ip_address,
    emergency_support_enabled, updated_by
  ) values (
    true, v_org_id, p_default_start_time, p_default_end_time, p_break_minutes,
    p_late_grace_minutes, p_early_leave_grace_minutes, coalesce(v_existing_ip,''),
    coalesce(p_emergency_support_enabled, true), auth.uid()
  ) on conflict (org_id) do update set
    default_start_time = excluded.default_start_time,
    default_end_time = excluded.default_end_time,
    break_minutes = excluded.break_minutes,
    late_grace_minutes = excluded.late_grace_minutes,
    early_leave_grace_minutes = excluded.early_leave_grace_minutes,
    emergency_support_enabled = excluded.emergency_support_enabled,
    updated_by = auth.uid(),
    updated_at = now()
  returning * into v_settings;

  return v_settings;
end $$;

revoke all on function public.save_organization_settings(time,time,integer,integer,integer,text,boolean) from public, anon;
grant execute on function public.save_organization_settings(time,time,integer,integer,integer,text,boolean) to authenticated;

commit;
