begin;

alter table public.organization_settings add column if not exists office_ip_address text not null default '';

update public.profiles
set role = 'super_admin', employee_number = '000000', is_active = true
where name = '관리자';

grant select, update on table public.workplaces to authenticated;

drop policy if exists "admin manages workplaces" on public.workplaces;
create policy "admin manages workplaces"
on public.workplaces
for all
to authenticated
using (public.is_attendance_admin())
with check (public.is_attendance_admin());

create or replace function public.save_workplace_settings(
  p_workplace_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_allowed_radius_meters integer,
  p_low_accuracy_threshold_meters integer
)
returns public.workplaces
language plpgsql
security definer
set search_path = public
as $$
declare
  v_workplace public.workplaces;
begin
  if not public.is_attendance_admin() then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_COORDINATES';
  end if;

  update public.workplaces
  set workplace_name = p_workplace_name,
      latitude = p_latitude,
      longitude = p_longitude,
      allowed_radius_meters = p_allowed_radius_meters,
      low_accuracy_threshold_meters = p_low_accuracy_threshold_meters
  where is_active = true
  returning * into v_workplace;

  if not found then
    insert into public.workplaces (
      workplace_name, latitude, longitude, allowed_radius_meters,
      low_accuracy_threshold_meters, is_active
    ) values (
      p_workplace_name, p_latitude, p_longitude, p_allowed_radius_meters,
      p_low_accuracy_threshold_meters, true
    ) returning * into v_workplace;
  end if;

  return v_workplace;
end $$;

revoke all on function public.save_workplace_settings(text, double precision, double precision, integer, integer) from public, anon;
grant execute on function public.save_workplace_settings(text, double precision, double precision, integer, integer) to authenticated;

create or replace function public.save_organization_settings(
  p_default_start_time time,
  p_default_end_time time,
  p_break_minutes integer,
  p_late_grace_minutes integer,
  p_early_leave_grace_minutes integer,
  p_office_ip_address text
)
returns public.organization_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.organization_settings;
begin
  if not public.is_attendance_admin() then
    raise exception 'ADMIN_REQUIRED';
  end if;

  insert into public.organization_settings (
    id, default_start_time, default_end_time, break_minutes,
    late_grace_minutes, early_leave_grace_minutes, office_ip_address, updated_by
  ) values (
    true, p_default_start_time, p_default_end_time, p_break_minutes,
    p_late_grace_minutes, p_early_leave_grace_minutes, trim(coalesce(p_office_ip_address,'')), auth.uid()
  )
  on conflict (id) do update
  set default_start_time = excluded.default_start_time,
      default_end_time = excluded.default_end_time,
      break_minutes = excluded.break_minutes,
      late_grace_minutes = excluded.late_grace_minutes,
      early_leave_grace_minutes = excluded.early_leave_grace_minutes,
      office_ip_address = excluded.office_ip_address,
      updated_by = auth.uid(),
      updated_at = now()
  returning * into v_settings;

  return v_settings;
end $$;

revoke all on function public.save_organization_settings(time, time, integer, integer, integer, text) from public, anon;
grant execute on function public.save_organization_settings(time, time, integer, integer, integer, text) to authenticated;

commit;

select name, employee_number, role, is_active
from public.profiles
where name = '관리자';
