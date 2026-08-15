begin;

-- 후속 보완 SQL이 시간외 승인 함수를 예전의 주 12시간 절대 차단 버전으로
-- 다시 정의했더라도, 최종 운영 함수에서는 서버 확인/사유 기록 방식만 사용합니다.
do $$
declare
  v_function oid;
  v_definition text;
  v_repaired_definition text;
begin
  select p.oid into v_function
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'review_correction_request'
    and pg_get_function_identity_arguments(p.oid) = 'p_request_id uuid, p_decision text, p_comment text';

  if v_function is null then
    raise exception 'REVIEW_CORRECTION_REQUEST_REQUIRED';
  end if;

  v_definition := pg_get_functiondef(v_function);
  v_repaired_definition := replace(
    v_definition,
    'if v_week_total + v_approved > 720 then raise exception ''WEEKLY_OVERTIME_LIMIT''; end if;',
    ''
  );

  if v_repaired_definition <> v_definition then
    execute v_repaired_definition;
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'review_correction_request'
    and pg_get_function_identity_arguments(p.oid) = 'p_request_id uuid, p_decision text, p_comment text';

  if v_definition like '%WEEKLY_OVERTIME_LIMIT%' then
    raise exception 'OVERTIME_REVIEW_FINAL_CONSISTENCY_FAILED';
  end if;
end $$;

-- 초과 승인 자체는 허용하되, 기존 서버 트리거가 일회성 확인과 사유를
-- 소비하도록 필수 구성요소가 모두 남아 있는지 함께 검증합니다.
do $$
begin
  if to_regclass('public.weekly_overtime_override_acknowledgements') is null
     or to_regprocedure('public.acknowledge_weekly_overtime_override(uuid,date,integer,text)') is null
     or to_regprocedure('public.consume_weekly_overtime_override(uuid,date,integer,text,uuid)') is null then
    raise exception 'WEEKLY_OVERTIME_OVERRIDE_SQL_REQUIRED';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgname = 'enforce_weekly_override_on_overtime_approval_trigger'
      and not tgisinternal
  ) then
    raise exception 'WEEKLY_OVERTIME_OVERRIDE_TRIGGER_REQUIRED';
  end if;
end $$;

notify pgrst, 'reload schema';
commit;

select '시간외 승인 최종 함수 정합성 보완 완료' as result;
