-- 먼저 Supabase Authentication > Users에서 기관 대표메일 사용자를 생성합니다.
-- 아래 ADMIN_EMAIL_REPLACE_BEFORE_RUN만 기관 대표메일로 바꾼 뒤 전체를 한 번 실행합니다.
-- 실제 이메일은 이 파일에 저장하거나 GitHub에 올리지 않습니다.

begin;

do $$
declare
  v_new_email text := lower(trim('ADMIN_EMAIL_REPLACE_BEFORE_RUN'));
  v_new_id uuid;
  v_old_id uuid;
begin
  if v_new_email = 'admin_email_replace_before_run' or position('@' in v_new_email) = 0 then
    raise exception 'ADMIN_EMAIL_REQUIRED';
  end if;

  select id into v_new_id
  from auth.users
  where lower(email) = v_new_email
  limit 1;

  if v_new_id is null then
    raise exception 'NEW_ADMIN_AUTH_USER_NOT_FOUND';
  end if;

  insert into public.profiles (id, email, name, employee_number, department)
  select
    id,
    lower(coalesce(email, '')),
    '관리자',
    'PENDING-' || left(id::text, 8),
    '운영'
  from auth.users
  where id = v_new_id
  on conflict (id) do nothing;

  select id into v_old_id
  from public.profiles
  where employee_number = '000000'
    and id <> v_new_id
  order by created_at
  limit 1;

  if v_old_id is not null then
    update public.profiles
    set
      email = 'archived-admin-' || left(id::text, 8) || '@attendance.invalid',
      employee_number = 'ARCHIVED-' || left(id::text, 8),
      is_active = false,
      updated_at = now()
    where id = v_old_id;
  end if;

  update public.profiles
  set
    email = v_new_email,
    name = '관리자',
    role = 'super_admin',
    employee_number = '000000',
    department = '운영',
    is_active = true,
    updated_at = now()
  where id = v_new_id;

  insert into public.attendance_audit_logs (
    employee_id,
    action_type,
    changed_field,
    before_value,
    after_value,
    reason,
    changed_by,
    changed_by_role
  ) values (
    v_new_id,
    'admin_account_migration',
    'super_admin',
    case when v_old_id is null then '기존 최고관리자 없음' else '기존 최고관리자 비활성화' end,
    '기관 대표메일 최고관리자 활성화',
    '기관 대표메일 관리자 계정 전환',
    v_new_id,
    'super_admin'
  );
end $$;

commit;

select name, employee_number, role, is_active
from public.profiles
where employee_number = '000000';
