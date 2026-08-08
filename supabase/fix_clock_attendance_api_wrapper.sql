begin;

-- PostgREST가 여러 매개변수 함수의 스키마를 찾지 못하는 경우를 피하기 위해
-- 서버 전용 출퇴근 함수를 JSON 입력 하나로 감쌉니다.
create or replace function public.clock_attendance_server_api(
  p_payload jsonb
) returns uuid
language sql
security definer
set search_path = public
as $$
  select public.clock_attendance_server(
    (p_payload ->> 'p_employee_id')::uuid,
    p_payload ->> 'p_action',
    (p_payload ->> 'p_latitude')::double precision,
    (p_payload ->> 'p_longitude')::double precision,
    (p_payload ->> 'p_accuracy')::numeric,
    p_payload ->> 'p_location_status',
    p_payload ->> 'p_ip_address',
    p_payload ->> 'p_note',
    (p_payload ->> 'p_idempotency_key')::uuid
  )
$$;

alter function public.clock_attendance_server_api(jsonb) owner to postgres;
revoke all on function public.clock_attendance_server_api(jsonb) from public, anon, authenticated;
grant execute on function public.clock_attendance_server_api(jsonb) to service_role;

notify pgrst, 'reload schema';
commit;

select '출퇴근 서버 API 연결 보완 완료' as result;
