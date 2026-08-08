-- 1. schema.sql과 upgrade_attendance_exceptions_and_clock_fix.sql 실행 후 실행합니다.
-- 2. Authentication 사용자를 스키마보다 먼저 만든 경우에도 profiles를 복구합니다.

insert into public.profiles (id, email, name, employee_number, department)
select
  id,
  lower(coalesce(email, '')),
  coalesce(nullif(raw_user_meta_data ->> 'name', ''), split_part(coalesce(email, '직원'), '@', 1)),
  coalesce(nullif(raw_user_meta_data ->> 'employee_number', ''), 'PENDING-' || left(id::text, 8)),
  coalesce(raw_user_meta_data ->> 'department', '')
from auth.users
where lower(coalesce(email, '')) in (
  'ADMIN_EMAIL_REPLACE_BEFORE_RUN',
  'employee1@attendance.invalid',
  'employee2@attendance.invalid'
)
on conflict (id) do update set email = excluded.email;

update public.profiles
set name = '최고관리자', role = 'super_admin', employee_number = '000000', department = '운영'
where email = 'ADMIN_EMAIL_REPLACE_BEFORE_RUN';

update public.profiles
set name = '직원 1', role = 'employee', employee_number = '260001', department = '상담팀'
where email = 'employee1@attendance.invalid';

update public.profiles
set name = '직원 2', role = 'employee', employee_number = '260002', department = '지원팀'
where email = 'employee2@attendance.invalid';

-- 사업장 좌표와 사무실 공인 IP는 임의값을 넣지 않습니다.
-- 관리자 로그인 후 설정 화면에서 실제 위치와 IP를 저장합니다.

-- 과거 근무유형은 데이터 호환을 위해 테이블에 남기되 신규 앱에서는 사용하지 않습니다.
update public.work_type_settings set is_active = (work_type = 'office');
