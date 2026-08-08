-- 직원은 사번만으로 기관을 자동 확인하므로 사번을 전체 기관에서 고유하게 관리합니다.
do $$
begin
  if exists (
    select 1 from public.profiles
    where role = 'employee'
    group by upper(employee_number)
    having count(*) > 1
  ) then
    raise exception 'DUPLICATE_ACTIVE_EMPLOYEE_NUMBER_EXISTS';
  end if;
end $$;

drop index if exists public.profiles_org_employee_number_unique_idx;
alter table public.profiles drop constraint if exists profiles_employee_number_key;
create unique index if not exists profiles_employee_number_global_unique_idx
  on public.profiles(upper(employee_number)) where role = 'employee';

create or replace function public.next_employee_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text := to_char(current_timestamp at time zone 'Asia/Seoul', 'YY');
  v_next integer;
begin
  perform pg_advisory_xact_lock(260001);
  select coalesce(max(substring(employee_number from 3 for 4)::integer), 0) + 1
  into v_next
  from public.profiles
  where employee_number ~ ('^' || v_prefix || '[0-9]{4}$');
  if v_next > 9999 then raise exception 'EMPLOYEE_NUMBER_CAPACITY_EXCEEDED'; end if;
  return v_prefix || lpad(v_next::text, 4, '0');
end $$;

revoke all on function public.next_employee_number() from public, anon, authenticated;
grant execute on function public.next_employee_number() to service_role;
