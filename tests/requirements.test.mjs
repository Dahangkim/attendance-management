import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Supabase schema includes protected attendance workflow", async () => {
  const sql = await read("supabase/schema.sql");
  for (const required of [
    "enable row level security",
    "clock_attendance",
    "review_correction_request",
    "close_attendance_month",
    "reopen_attendance_month",
    "attendance_audit_logs",
    "attendance_locations",
    "recalculate_attendance_month",
  ]) assert.ok(sql.includes(required), `${required} is required`);
  assert.ok(sql.includes("revoke delete on public.attendance_audit_logs"));
});

test("client does not include a Supabase service role key", async () => {
  const files = await Promise.all([read("app/attendance-app.tsx"), read("lib/supabase.ts"), read(".env.example")]);
  assert.equal(files.join("\n").includes("SERVICE_ROLE"), false);
  assert.equal(files.join("\n").includes("service_role"), false);
});

test("repository files do not contain the real administrator email", async () => {
  const files = await Promise.all([read("README.md"), read("supabase/seed.sql"), read("supabase/migrate_super_admin.sql"), read("app/attendance-app.tsx")]);
  const removedEmail = ["suhyeon.kim", "jwr.or.kr"].join("@");
  assert.equal(files.join("\n").includes(removedEmail), false);
  assert.ok(files.join("\n").includes("ADMIN_EMAIL_REPLACE_BEFORE_RUN"));
});

test("super admin migration keeps history and disables the previous account", async () => {
  const sql = await read("supabase/migrate_super_admin.sql");
  assert.ok(sql.includes("NEW_ADMIN_AUTH_USER_NOT_FOUND"));
  assert.ok(sql.includes("is_active = false"));
  assert.ok(sql.includes("employee_number = '000000'"));
  assert.ok(sql.includes("admin_account_migration"));
});

test("signed-in users can change their own password", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/admin-reset-password/route.ts");
  const password = await read("lib/auth-password.ts");
  assert.ok(app.includes("PasswordChangeModal"));
  assert.ok(app.includes("현재 비밀번호"));
  assert.ok(app.includes("supabase.auth.updateUser({ password: toSupabasePassword(newPassword) })"));
  assert.ok(app.includes('event === "PASSWORD_RECOVERY"'));
  assert.ok(app.includes("newPassword.length < 6"));
  assert.ok(app.includes("isPrivilegedPassword(newPassword)"));
  assert.ok(app.includes('supabase.rpc("complete_required_password_change")'));
  assert.ok(route.includes("password.length < 6"));
  assert.ok(password.includes("PRIVILEGED_PASSWORD_MIN_LENGTH = 8"));
  assert.ok(password.includes("/[^A-Za-z0-9]/"));
});

test("password results stay visible as a fixed seven-second notice", async () => {
  const app = await read("app/attendance-app.tsx");
  const css = await read("app/globals.css");
  assert.ok(app.includes("window.setTimeout(() => setNotice(null), 7_000"));
  assert.ok(app.includes("비밀번호가 변경되었습니다"));
  assert.ok(css.includes("position: fixed"));
  assert.ok(css.includes("z-index: 1200"));
});

test("installed app sessions persist and expired sessions return to login", async () => {
  const app = await read("app/attendance-app.tsx");
  const client = await read("lib/supabase.ts");
  const readme = await read("README.md");
  assert.ok(client.includes("persistSession: true"));
  assert.ok(app.includes("restoreSession"));
  assert.ok(app.includes("verifyWhenVisible"));
  assert.ok(app.includes("로그인이 만료되었습니다. 다시 로그인해 주세요."));
  assert.ok(app.includes('event === "SIGNED_OUT"'));
  assert.ok(app.includes("로그인은 유지 중이지만 직원 정보를 불러오지 못했습니다"));
  assert.ok(!app.includes("signOutForInactivity"));
  assert.ok(!app.includes("PC_IDLE_TIMEOUT_MS"));
  assert.ok(readme.includes("일반 브라우저에서는 새로고침하는 동안에만"));
  assert.ok(readme.includes("브라우저 창을 완전히 닫았다가 다시 열면 다시 로그인"));
  assert.ok(readme.includes("휴대전화 홈 화면에 설치한 앱에서는"));
  assert.ok(readme.includes("세션이 실제로 만료되거나 로그아웃되면"));
});

test("organization admin employee password reset stays server-side and is audited", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/admin-reset-password/route.ts");
  assert.ok(app.includes('/api/admin-reset-password'));
  assert.ok(app.includes("관리자 현재 비밀번호"));
  assert.ok(route.includes("SUPABASE_SECRET_KEY"));
  assert.ok(route.includes('["admin", "org_admin"].includes(actor.role)'));
  assert.ok(route.includes('target.org_id !== actor.org_id'));
  assert.ok(route.includes("admin.updateUserById"));
  assert.ok(route.includes('action_type: "password_reset"'));
});

test("geolocation is requested only from explicit attendance and admin-setting workflows", async () => {
  const app = await read("app/attendance-app.tsx");
  const geo = await read("lib/geo.ts");
  assert.ok(app.includes("startClock"));
  assert.ok(app.includes("detectCurrentLocationProposal"));
  assert.ok(app.includes("현재 위치 자동입력"));
  assert.ok(app.includes("현재 IP 자동입력"));
  assert.ok(app.includes("위치 변경 승인 요청"));
  assert.ok(app.includes("requestCurrentLocation"));
  assert.ok(geo.includes("getCurrentPosition"));
  assert.equal(geo.includes("watchPosition"), false);
});

test("one login form uses employee number for staff and organization admins without exposing a staff list", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/employee-login/route.ts");
  const legacyRoute = await read("app/api/staff-login-options/route.ts");
  assert.ok(app.includes("loginIdentifier"));
  assert.ok(app.includes("사번 또는 최고관리자 이메일"));
  assert.ok(app.includes("사번"));
  assert.ok(route.includes('.ilike("employee_number", employeeNumber)'));
  assert.ok(route.includes('.in("role", ["employee", "team_lead", "org_admin", "admin", "super_admin"])'));
  assert.ok(route.includes('.eq("id", profile.org_id)'));
  assert.ok(legacyRoute.includes("STAFF_LOGIN_LIST_DISABLED"));
  assert.ok(!app.includes("직원 선택<select"));
  assert.ok(!app.includes('aria-label="로그인 유형"'));
  assert.ok(app.includes("모든 계정은 사번으로 로그인할 수 있으며, 최고관리자는 이메일도 사용할 수 있습니다"));
});

test("employee number changes can include a known temporary login password", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/admin-employee-account/route.ts");
  assert.ok(app.includes("새 임시 비밀번호, 선택"));
  assert.ok(app.includes("employeeNumber, department:"));
  assert.ok(app.includes("password }"));
  assert.ok(route.includes("...(password ? { password: toSupabasePassword(password) } : {})"));
  assert.ok(route.includes('password ? "AUTH_PASSWORD_UPDATE_FAILED"'));
  assert.ok(route.includes("passwordChanged: Boolean(password)"));
});

test("desktop low-accuracy records use an explicit office-PC fallback", async () => {
  const app = await read("app/attendance-app.tsx");
  const geo = await read("lib/geo.ts");
  assert.ok(app.includes("사무실 PC에서 기록"));
  assert.ok(app.includes("오차 ${locationResult.accuracy}m"));
  assert.ok(geo.includes("사업장 안팎을 판정할 수 없습니다"));
});

test("all authenticated employees load the active workplace from Supabase", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes('const workplaceQuery = supabase.from("workplaces")'));
  assert.ok(app.includes("recordResult, todayResult, openRecordResult, requestResult, workplaceResult"));
});

test("protected workplace settings require the super-admin approval route", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/repair_protected_workplace_approval_only.sql");
  assert.ok(!app.includes('supabase.rpc("save_workplace_settings"'));
  assert.ok(app.includes('onRequest(event.currentTarget, "workplace_location")'));
  assert.ok(sql.includes('revoke all on function public.save_workplace_settings'));
  assert.ok(sql.includes('public.is_super_admin()'));
});

test("organization settings persist work hours and late grace", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/schema.sql");
  assert.ok(app.includes('supabase.rpc("save_organization_settings"'));
  assert.ok(app.includes("organizationDraft.late_grace_minutes"));
  assert.ok(sql.includes("save_organization_settings"));
  assert.ok(sql.includes("late_grace_minutes = excluded.late_grace_minutes"));
});

test("clock actions use a server-trusted office IP and block direct browser RPC", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/clock-attendance/route.ts");
  const ipHelper = await read("app/api/_lib/client-ip.ts");
  const sql = await read("supabase/upgrade_secure_clock_and_overnight.sql");
  assert.ok(app.includes('fetch("/api/clock-attendance"'));
  assert.ok(!app.includes('supabase.rpc("clock_attendance"'));
  assert.ok(app.includes("일반 출근, 사무실 IP 일치"));
  assert.ok(route.includes("resolveRequestIp(request)"));
  assert.ok(ipHelper.includes("cf-connecting-ip"));
  assert.ok(route.includes("adminClient.auth.getUser(token)"));
  assert.ok(route.includes('/rest/v1/rpc/clock_attendance_server_api'));
  assert.ok(route.includes('apikey: secretKey'));
  assert.ok(route.includes("p_ip_address: trustedIp || null"));
  assert.ok(!route.includes("missingServerFunction"));
  assert.ok(!route.includes('userClient.rpc("clock_attendance"'));
  assert.ok(sql.includes("clock_attendance_server"));
  assert.ok(sql.includes("clock_attendance_server_api"));
  assert.ok(sql.includes("to service_role"));
  assert.ok(sql.includes("from public, anon, authenticated"));
  assert.ok(sql.includes("v_ip_matched"));
  assert.ok(sql.includes("clock_in_ip_matched"));
});

test("overnight clock-out continues the latest open record from the previous day", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_secure_clock_and_overnight.sql");
  assert.ok(app.includes("openRecordQuery"));
  assert.ok(app.includes('is("clock_out_at", null)'));
  assert.ok(app.includes("action === \"clock_out\" && !openRecord?.clock_in_at"));
  assert.ok(app.includes("record={todayRecord || openRecord} exception={openRecord ? undefined : todayException}"));
  assert.ok(app.includes("아직 퇴근하지 않은 출근 기록이 있습니다"));
  assert.ok(sql.includes("work_date between v_today - 2 and v_today"));
  assert.ok(sql.includes("v_policy.max_open_shift_hours"));
  assert.ok(sql.includes("clock_in_at >= v_now - make_interval(hours => v_policy.max_open_shift_hours)"));
  assert.ok(sql.includes("v_work_date := v_record.work_date"));
  assert.ok(sql.includes("calculate_raw_overtime_minutes(v_work_date"));
});

test("clearing an attendance time allows the employee to record that action again", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/clock-attendance/route.ts");
  const sql = await read("supabase/fix_reclock_after_admin_time_clear.sql");
  const install = await read("supabase/install_current.sql");
  for (const source of [sql, install]) {
    assert.ok(source.includes("cleanup_attendance_events_after_time_clear"));
    assert.ok(source.includes("old.clock_out_at is not null and new.clock_out_at is null"));
    assert.ok(source.includes("action_type = 'clock_out'"));
    assert.ok(source.includes("old.clock_in_at is not null and new.clock_in_at is null"));
    assert.ok(source.includes("action_type in ('clock_in','clock_out')"));
  }
  assert.ok(app.includes('clockErrorMessage(error, action)'));
  assert.ok(app.includes('action === "clock_out" ? "오늘 퇴근 요청이 이미 처리됐습니다.'));
  assert.ok(route.includes('if (action === "clock_out")'));
  assert.ok(route.includes('.is("clock_out_at", null)'));
  assert.ok(route.includes('from("attendance_events")'));
  assert.ok(route.includes('.eq("action_type", "clock_out")'));
  assert.ok(route.includes('"CLOCK_EVENT_CLEANUP_FAILED"'));
  assert.ok(route.includes('"X-Clock-Server-Version": CLOCK_SERVER_VERSION'));
  assert.ok(route.includes('await callClockRpc()'));
});

test("current Supabase installation is available as one ordered SQL file", async () => {
  const install = await read("supabase/install_current.sql");
  const readme = await read("README.md");
  for (const section of ["supabase/schema.sql", "upgrade_overtime_leave_comp_time.sql", "upgrade_unified_requests_and_admin_review.sql", "upgrade_employee_management.sql", "upgrade_secure_clock_and_overnight.sql"]) assert.ok(install.includes(section));
  assert.ok(install.indexOf("-- supabase/upgrade_overtime_leave_comp_time.sql") < install.indexOf("-- supabase/upgrade_unified_requests_and_admin_review.sql"));
  assert.ok(install.indexOf("-- supabase/upgrade_unified_requests_and_admin_review.sql") < install.indexOf("-- supabase/upgrade_secure_clock_and_overnight.sql"));
  for (const invalidText of ["+begin;", "+Exit code:", "Wall time:", "Output:"]) assert.ok(!install.includes(invalidText));
  assert.ok(readme.includes("supabase/install_current.sql"));
  assert.ok(readme.includes("upgrade_secure_clock_and_overnight.sql"));
});

test("attendance constraint repair accepts current location and review states", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/repair_attendance_check_constraints.sql");
  assert.ok(app.includes('code === "23514"'));
  assert.ok(sql.includes("attendance_records_attendance_status_check"));
  assert.ok(sql.includes("'admin_review'"));
  assert.ok(sql.includes("'low_accuracy'"));
  assert.ok(sql.includes("where work_type = 'office'"));
});

test("reclocking a soft-deleted day clears the previous clock-out", async () => {
  const schema = await read("supabase/schema.sql");
  const upgrade = await read("supabase/upgrade_ip_edit_delete.sql");
  const repair = await read("supabase/repair_reclock_after_delete.sql");
  for (const sql of [schema, upgrade]) {
    assert.ok(sql.includes("clock_out_at = null"));
    assert.ok(sql.includes("clock_out_location_status = 'not_checked'"));
    assert.ok(sql.includes("clock_out_ip_matched = false"));
  }
  assert.ok(repair.includes("old.deleted_at is not null"));
  assert.ok(repair.includes("new.deleted_at is null"));
  assert.ok(repair.includes("before update on public.attendance_records"));
});

test("admins can update and soft-delete attendance with audit reasons", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_ip_edit_delete.sql");
  assert.ok(app.includes('supabase.rpc("admin_update_attendance"'));
  assert.ok(app.includes('supabase.rpc("admin_delete_attendance"'));
  assert.ok(sql.includes("admin_update_attendance"));
  assert.ok(sql.includes("admin_delete_attendance"));
  assert.ok(sql.includes("deleted_at is null"));
  assert.ok(sql.includes("attendance_audit_logs"));
});

test("notices automatically close after seven seconds", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("7_000"));
  assert.ok(app.includes("setNotice(null)"));
});

test("monthly closing is visible and super admins can reopen it", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("monthClosing"));
  assert.ok(app.includes("마감 완료"));
  assert.ok(app.includes('supabase.rpc("reopen_attendance_month"'));
  assert.ok(app.includes("월 마감 해제"));
});

test("audit history exports CSV and Excel", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("exportAuditCsv"));
  assert.ok(app.includes("exportAuditExcel"));
  assert.ok(app.includes("_변경이력.csv"));
  assert.ok(app.includes("_변경이력.xlsx"));
});

test("month picker returns directly to the current month", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("이번 달"));
  assert.ok(app.includes("onChange(thisMonth)"));
});

test("work details are not employee-selected and place labels are automatic", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_secure_clock_and_overnight.sql");
  assert.equal(app.includes("오늘 근무유형"), false);
  assert.ok(sql.includes("p_employee_id, v_work_date, 'office'"));
  assert.ok(app.includes('return action === "clock_in" ? "직출" : "직퇴"'));
  assert.ok(app.includes("사업장 밖에서 기록하는 사유"));
});

test("approved attendance exceptions keep approver and audit history", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_attendance_exceptions_and_clock_fix.sql");
  assert.ok(app.includes('adminView === "exceptions"'));
  assert.ok(app.includes("예외 근무 기간입니다"));
  assert.ok(sql.includes("approved_by"));
  assert.ok(sql.includes("admin_create_attendance_exception"));
  assert.ok(sql.includes("admin_cancel_attendance_exception"));
  assert.ok(sql.includes("attendance_audit_logs"));
});

test("audit and correction status are browsed by month", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("auditMonth"));
  assert.ok(app.includes("requestMonth"));
  assert.ok(app.includes('<MonthPicker value={auditMonth}'));
  assert.ok(app.includes('<MonthPicker value={requestMonth}'));
});

test("overtime, annual leave, comp time, and monthly summaries follow institution rules", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_overtime_leave_comp_time.sql");
  assert.ok(sql.includes("v_worked_minutes - 480"));
  assert.ok(sql.includes("p_approved_minutes not in (60,90,120,150,180,210,240)"));
  assert.ok(sql.includes("WEEKLY_OVERTIME_LIMIT"));
  assert.ok(sql.includes("v_week_total + p_approved_minutes > 720"));
  assert.ok(sql.includes("INSUFFICIENT_COMP_TIME_BALANCE"));
  assert.ok(sql.includes("comp_time_credits"));
  assert.ok(sql.includes("v_record.work_date + 30"));
  assert.ok(sql.includes("order by c.expires_on"));
  assert.ok(sql.includes("comp_time_balances_view"));
  for (const text of ["연차 1일", "반차 0.5일", "반반차 0.25일", "1시간차 0.125일", "대체휴무 사용", "병가", "사무실 근무일", "총 근무일"]) assert.ok(app.includes(text));
  for (const header of ["출근시간", "퇴근시간", "시간외근무", "대휴", "휴가", "출장", "병가"]) assert.ok(app.includes(header));
});

test("monthly Excel export creates one attendance sheet per employee", async () => {
  const app = await read("app/attendance-app.tsx");
  for (const text of ["직원별 요약", "daysInMonth", "workbook.addWorksheet(safeName", "직원별_월간출근부.xlsx"]) assert.ok(app.includes(text));
  for (const header of ["일자", "요일", "출근시간", "퇴근시간", "출근", "시간외근무", "대휴", "휴가", "출장", "병가"]) assert.ok(app.includes(header));
});

test("any year of Korean holidays can be refreshed and manually managed", async () => {
  const app = await read("app/attendance-app.tsx");
  const route = await read("app/api/korean-holidays/route.ts");
  assert.ok(app.includes("선택 연도 다시 불러오기"));
  assert.ok(app.includes("기관 휴일 직접 추가"));
  assert.ok(app.includes("editHoliday"));
  assert.ok(app.includes("removeHoliday"));
  assert.ok(app.includes('from("organization_holidays").delete()'));
  assert.ok(app.includes('onConflict: "org_id,holiday_date"'));
  assert.ok(route.includes("ko.south_korea%23holiday"));
  assert.ok(route.includes('split("BEGIN:VEVENT")'));
  assert.ok(route.includes('!== "공휴일"'));
});

test("attendance status is recalculated after an approved time correction", async () => {
  const sql = await read("supabase/fix_attendance_status_after_time_edit.sql");
  assert.ok(sql.includes("derive_attendance_status"));
  assert.ok(sql.includes("before update of clock_in_at, clock_out_at"));
  assert.ok(sql.includes("attendance_status = public.derive_attendance_status(ar)"));
  assert.ok(sql.includes("v_default_start_time + make_interval"));
  assert.ok(sql.includes("to_jsonb(p_record)->>'leave_type'"));
  assert.ok(!sql.includes("p_record.leave_type"));
});

test("configured app waits for authentication data without flashing demo records", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("authReady"));
  assert.ok(app.includes("dataReady"));
  assert.ok(app.includes("<AppLoadingScreen branding={tenantBranding} />"));
  assert.ok(app.includes("isSupabaseConfigured ? [] : demoRecords"));
});

test("missing attendance is not automatically finalized as absence", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/fix_attendance_status_after_time_edit.sql");
  assert.ok(sql.includes("자동 결근 판정 폐지"));
  assert.ok(sql.includes("휴가 또는 기타 사유 확인 필요"));
  assert.ok(sql.includes("work_type in ('field', 'education', 'business_trip')"));
  assert.ok(app.includes("ATTENDANCE_STATUS_FILTERS"));
  assert.ok(!app.includes("Object.entries(STATUS_LABEL)"));
});

test("monthly workbook keeps result sheets, full clock logs, history, holidays, and units", async () => {
  const app = await read("app/attendance-app.tsx");
  for (const text of ["전체 출퇴근 로그", "변경 이력", "출근 GPS 정확도", "퇴근 IP", "비고", '"✓"', "Number.isInteger(value)", '0"${unit}"', "holidayMap"]) assert.ok(app.includes(text));
  for (const text of ["담당", "소장", "업무내용", "발생 시간외근무 연결 필요", "leaveUnitLabel(annualMinutes)", "compTimeSources"]) assert.ok(app.includes(text));
  for (const text of ['`${year}년 ${month}월 ${person.name} 출근부 및 시간외근무 대장`', 'sheet.mergeCells("J2:K2")', 'sheet.getCell("J3").value = "담당"', 'sheet.getCell("J4").value = "소장"', 'sheet.getCell("A4").value = "직위"', 'sheet.getRow(5).values = headers']) assert.ok(app.includes(text));
  assert.ok(!app.includes("`${year}년 ( ${month}월 ) ${person.name} 출근부 및 시간외근무 대장`"));
  assert.ok(!app.includes("sheet.getCell(rowIndex, 6).numFmt = '0.##"));
});

test("unified requests use exact lunch time and admins can complete attendance review", async () => {
  const app = await read("app/attendance-app.tsx");
  const css = await read("app/globals.css");
  const sql = await read("supabase/upgrade_unified_requests_and_admin_review.sql");
  for (const text of ["business_trip", "overtime", "other_leave", "12시부터 13시", "admin_confirm_attendance_record", "확인 완료"]) assert.ok(app.includes(text));
  for (const text of ["time '12:00'", "time '13:00'", "calculate_attendance_request_minutes", "admin_confirm_attendance_record", "admin_review_overtime", "admin_reopen_correction_request", "admin_update_attendance_request", "recalculate_overtime_after_attendance_change", "least(240", "drop view if exists public.attendance_records_view", "WEEKLY_OVERTIME_LIMIT"]) assert.ok(sql.includes(text));
  for (const text of ["approvedRequestMinutesForDate", "otherLeave?.request_subtype", "approvedLeaveRequests", "장기재직휴가", "request-status-tabs", "재검토", "연결된 근태기록 수정"]) assert.ok(app.includes(text));
  assert.ok(app.includes('requestType === "overtime" ? targetDate'));
  assert.ok(css.includes('option[value="overtime"]:checked'));
  assert.ok(css.includes('input[name="end_date"]'));
});

test("admins can correct approved request types before reapproval and workbook reflection", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_approved_request_editing.sql");
  for (const text of ["canChangeType", "p_request_type", "재승인된 연차와 휴가는 월별 출근부에 반영", "approvedRequestMinutesForDate", "otherLeave?.request_subtype"]) assert.ok(app.includes(text));
  for (const text of ["INVALID_REQUEST_TYPE", "request_type = v_request_type", "approved_minutes = 0", "status = 'pending'", "request_edited", "notify pgrst, 'reload schema'"]) assert.ok(sql.includes(text));
});

test("admins can classify confirmed early leave and register full-day leave exceptions", async () => {
  const app = await read("app/attendance-app.tsx");
  const types = await read("lib/types.ts");
  const classifySql = await read("supabase/upgrade_admin_leave_classification.sql");
  const exceptionSql = await read("supabase/upgrade_leave_exceptions.sql");
  const repairSql = await read("supabase/fix_admin_leave_apply_42703.sql");
  for (const text of ["휴가 반영", "admin_apply_leave_to_attendance_record", "attendanceLeaveLabel", "종일 대체휴무", "출퇴근 기록 예외 일정"]) assert.ok(app.includes(text));
  for (const text of ["admin_leave_applied", "approved_minutes", "correction_request_id"]) assert.ok(classifySql.includes(text) || exceptionSql.includes(text));
  for (const sql of [classifySql, exceptionSql]) {
    assert.ok(sql.includes("from public.monthly_closings"));
    assert.ok(!sql.includes("v_record.is_closed"));
  }
  for (const text of ["annual_leave", "comp_time", "sick_leave", "other_leave"]) assert.ok(types.includes(text) && exceptionSql.includes(text));
  assert.ok(exceptionSql.includes("set approved_minutes = calculated_minutes"));
  assert.ok(exceptionSql.includes("status = 'rejected'"));
  for (const text of ["add column if not exists leave_type", "allocate_comp_time_usage_without_negative", "remaining_minutes = remaining_minutes - v_use", "잔액은 음수로 계산하지 않습니다"]) assert.ok(repairSql.includes(text));
  assert.ok(app.includes("재검토"));
});

test("admins can add missing work records and approved requests become exceptions", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_admin_manual_attendance_and_request_exceptions.sql");
  for (const text of ["근무기록 추가", "AttendanceCreateModal", "LeaveApplyModal", "type=\"checkbox\"", "출장과 종일 휴가"]) assert.ok(app.includes(text));
  for (const text of ["admin_create_attendance_record", "RECORD_ALREADY_EXISTS", "sync_approved_request_to_attendance_exception", "request.request_type = 'business_trip'", "correction_request_id"]) assert.ok(sql.includes(text));
  assert.ok(!app.includes("숙박 출장"));
  assert.ok(!app.includes("1부터 4까지의 번호"));
});

test("iOS users receive manual home screen installation guidance", async () => {
  const app = await read("app/attendance-app.tsx");
  const layout = await read("app/layout.tsx");
  const manifest = await read("app/api/manifest/route.ts");
  for (const text of ["iosInstallAvailable", "IosInstallGuide", "홈 화면에 추가", "웹 앱으로 열기", "iOS Chrome", "navigatorWithStandalone"]) assert.ok(app.includes(text));
  assert.ok(layout.includes("appleWebApp"));
  assert.ok(layout.includes('apple: icon'));
  assert.ok(manifest.includes('display: "standalone"'));
});

test("audit history uses readable Korean labels", async () => {
  const app = await read("app/attendance-app.tsx");
  for (const text of ["시간외근무 승인시간", "시간외근무를 반려했습니다", "요청 재검토", "auditDescription", "readableAuditValue"]) assert.ok(app.includes(text));
  assert.ok(!app.includes('<b>{log.changed_field}</b>을 변경했습니다.'));
});

test("audit history classifies by organization scope and keeps long values inside cards", async () => {
  const [app, css] = await Promise.all([read("app/attendance-app.tsx"), read("app/globals.css")]);
  assert.ok(app.includes('const auditCategory = (log: AuditLog)'));
  assert.ok(app.includes('superAdminOrganizationActions.has(log.action_type)'));
  assert.ok(app.includes('return "institution"'));
  assert.ok(app.includes('governanceActions.has(log.action_type)'));
  assert.ok(app.includes('independentActions.has(log.action_type)'));
  assert.ok(!app.includes('if (!log.org_id) return "independent"'));
  assert.ok(app.includes('"이전 기관 화면 설정"'));
  assert.ok(app.includes('"변경된 기관 화면 설정"'));
  assert.ok(css.includes(".audit-values span"));
  assert.ok(css.includes("overflow-wrap: anywhere"));
  assert.match(css, /\.audit-restore-button \{[^}]*color: var\(--green-deep\)/);
  assert.doesNotMatch(css, /\.audit-restore-button \{[^}]*color: var\(--brand\)/);
  assert.ok(app.includes('className="request-category-tabs audit-category-tabs"'));
  assert.ok(!app.includes('(superAdmin || organizationChanges.length > 0 || sourceLogs.some'));
  assert.ok(css.includes(".audit-category-tabs button.active"));
  assert.ok(css.includes("color: var(--green-contrast)"));
});

test("audit exports include every category instead of only the selected tab", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes('const exportLogs = sourceLogs.filter'));
  assert.ok(app.includes('["분류", "처리일시"'));
  assert.ok(app.includes('category: auditCategoryLabel(auditCategory(log))'));
  assert.ok(app.includes('sheet.autoFilter = { from: "A1", to: "J1" }'));
  assert.ok(app.includes('governanceActions.has(log.action_type)'));
  assert.ok(!app.includes('const values = filtered.map((log)'));
});

test("work policy toggles keep each explanation with its control", async () => {
  const [app, css] = await Promise.all([read("app/attendance-app.tsx"), read("app/globals.css")]);
  assert.ok(app.includes('className="policy-toggle-grid"'));
  assert.equal((app.match(/className="policy-toggle-card"/g) || []).length, 4);
  assert.ok(app.includes('className="settings-save-actions"'));
  assert.ok(css.includes(".policy-toggle-grid"));
});

test("employees can resubmit requests and admins can restore deleted attendance", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_unified_requests_and_admin_review.sql");
  for (const text of ["내 신청내역", "수정해서 다시 제출", "employee_resubmit_attendance_request", "삭제 취소, 기록 복원", "admin_restore_attendance", "request_resubmitted", "admin_restore"]) assert.ok(app.includes(text) || sql.includes(text));
  assert.ok(sql.includes("REQUEST_NOT_RESUBMITTABLE"));
  assert.ok(sql.includes("ACTIVE_RECORD_ALREADY_EXISTS"));
});

test("custom clock rejection shows its actionable server reason", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("INACTIVE_OR_UNKNOWN_USER"));
  assert.ok(app.includes("로그인 계정과 직원 정보가 연결되지 않았거나 사용 중지 상태"));
  assert.ok(app.includes('code === "P0001"'));
  assert.ok(app.includes("거부 사유"));
  assert.ok(app.includes("isClockAuthenticationError"));
  assert.ok(app.includes("로그인 유지 정보가 만료되었습니다"));
  assert.ok(app.includes('signOut({ scope: "local" })'));
});

test("report viewers keep employee attendance and receive read-only monthly exports", async () => {
  const app = await read("app/attendance-app.tsx");
  const types = await read("lib/types.ts");
  const sql = await read("supabase/upgrade_report_viewer_and_extra_comp_time.sql");
  for (const text of ["can_view_reports", "직원 현황", "부관리자 조회", "변경 이력", "ReportViewer", "부관리자 지정", "admin_set_report_viewer"]) assert.ok(app.includes(text) || types.includes(text) || sql.includes(text));
  assert.ok(sql.includes("can_view_attendance_reports"));
  assert.ok(sql.includes('report_viewer_changed'));
  assert.ok(sql.includes('role = \'employee\''));
  assert.ok(!app.includes('currentProfile?.can_view_reports && employeeView === "team_reports" && <MonthlyAdmin'));
});

test("comp time uses the full actual extra work independently from overtime approval", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/fix_comp_time_recognition_rule.sql");
  assert.ok(app.includes("실제 추가근무 5시간이면 시간외근무는 최대 4시간, 대체휴무는 5시간 적립 가능"));
  assert.ok(app.includes("compTimeLimit"));
  assert.ok(sql.includes("p_comp_time_minutes % 30"));
  assert.ok(sql.includes("p_comp_time_minutes > v_comp_time_limit"));
  assert.ok(sql.includes("sum(approved_overtime_minutes)"));
  assert.ok(sql.includes("v_week_total + p_approved_minutes > 720"));
  assert.ok(!sql.includes("p_approved_minutes + p_comp_time_minutes > v_raw_minutes"));
  assert.ok(!sql.includes("sum(approved_overtime_minutes + comp_time_eligible_minutes)"));
  assert.ok(sql.includes("insert into public.comp_time_credits"));
  assert.ok(sql.includes("v_record.work_date + 30"));
});

test("organization admins can create employees and preserve records when staff leave", async () => {
  const app = await read("app/attendance-app.tsx");
  const createRoute = await read("app/api/admin-create-employee/route.ts");
  const sql = await read("supabase/upgrade_org_governance_and_work_policies.sql");
  for (const text of ["새 직원 추가", "퇴사 처리", "재활성화", "EmployeeCreateModal", "자동 발급", "admin_set_employee_active"]) assert.ok(app.includes(text) || sql.includes(text));
  assert.ok(createRoute.includes("admin.createUser"));
  assert.ok(createRoute.includes("email_confirm: true"));
  assert.ok(createRoute.includes("@attendance.invalid"));
  assert.ok(createRoute.includes('new Set(["admin", "org_admin"])'));
  assert.ok(!createRoute.includes('"team_lead", "super_admin"'));
  assert.ok(sql.includes("can_view_reports = case when p_active then can_view_reports else false end"));
  assert.ok(sql.includes("employee_deactivated"));
  assert.ok(sql.includes("employee_reactivated"));
});

test("admins can batch-create attendance and exception schedules including external training", async () => {
  const app = await read("app/attendance-app.tsx");
  const types = await read("lib/types.ts");
  const sql = await read("supabase/upgrade_batch_training_actual_overtime.sql");
  const install = await read("supabase/install_current.sql");
  for (const text of ["admin_create_attendance_records", "admin_create_attendance_exceptions", "p_employee_ids uuid[]", "skipped_names", "external_training"]) {
    assert.ok(sql.includes(text));
    assert.ok(install.includes(text));
  }
  for (const text of ["전체 선택", "전체 해제", "getAll(\"employee_id\")", "외부교육", "명 승인 등록"]) assert.ok(app.includes(text));
  assert.ok(types.includes('"external_training"'));
});

test("overtime approval uses actual clock records and approved mid-day leave is excluded", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/upgrade_batch_training_actual_overtime.sql");
  for (const text of [
    "approved_leave_minutes_during_attendance",
    "recalculate_attendance_after_leave_request",
    "sync_overtime_request_to_attendance",
    "ACTUAL_OVERTIME_REQUIRED",
    "least(240,v_request.calculated_minutes,v_record.recorded_overtime_minutes)",
    "OVERTIME_REQUEST_LIMIT",
    "time '12:00'",
    "time '13:00'",
  ]) assert.ok(sql.includes(text));
  for (const text of ["실제 인정 가능", "최대 승인", "퇴근기록 대기", "반려", "재검토"]) assert.ok(app.includes(text));
});

test("manual overtime approval is not overwritten by the requested maximum", async () => {
  const sql = await read("supabase/fix_overtime_manual_approval_overwrite.sql");
  const upgrade = await read("supabase/upgrade_batch_training_actual_overtime.sql");
  const install = await read("supabase/install_current.sql");
  const approvalPreference = "coalesce(nullif(new.approved_minutes,0),new.calculated_minutes,0)";
  for (const text of ["sync_overtime_request_to_attendance", approvalPreference, "approved_overtime_minutes = v_final"]) {
    assert.ok(sql.includes(text));
    assert.ok(upgrade.includes(text));
    assert.ok(install.includes(text));
  }
});

test("attendance editing recovers stale month flags and shows actionable errors", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/fix_admin_edit_after_reopen.sql");
  const install = await read("supabase/install_current.sql");
  for (const text of ["v_month_closed", "set is_closed = false", "p_work_type is distinct from v_record.work_type", "quarter_day", "hourly_leave", "v_clock_out + interval '1 day'"]) {
    assert.ok(sql.includes(text));
    assert.ok(install.includes(text));
  }
  for (const text of ["오류코드", "INVALID_TIME_RANGE", "INVALID_WORK_TYPE", "INVALID_STATUS", "CLOCK_IN_REQUIRED"]) assert.ok(app.includes(text));
  assert.ok(sql.includes("create or replace function public.recognized_overtime_minutes"));
  assert.ok(sql.includes("least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)"));
});

test("leave balances block negative usage and special leave stays separate from annual leave", async () => {
  const app = await read("app/attendance-app.tsx");
  const types = await read("lib/types.ts");
  const sql = await read("supabase/upgrade_leave_balances_and_special_leave.sql");
  const install = await read("supabase/install_current.sql");
  for (const text of [
    "annual_leave_entitlements",
    "annual_leave_balances_view",
    "comp_time_credit_details_view",
    "total_granted_comp_time_minutes",
    "used_comp_time_minutes",
    "expired_comp_time_minutes",
    "monthly_overtime_after_comp_view",
    "comp_time_used_from_source_minutes",
    "overtime_after_comp_minutes",
    "COMP_TIME_BALANCE_INSUFFICIENT",
    "ANNUAL_LEAVE_BALANCE_INSUFFICIENT",
    "admin_extend_comp_time_credit",
    "admin_delete_annual_leave_entitlement",
    "annual_leave_entitlement_deleted",
    "special_leave",
  ]) {
    assert.ok(sql.includes(text));
    assert.ok(install.includes(text));
  }
  for (const text of ["휴가 잔액", "연차 부여내역 등록", "연차 부여내역 수정", "수정 취소", "연차 부여내역 삭제", "대체휴무 시작 잔액 등록", "대체휴무 적립", "사용 누계", "사용 가능", "기한 만료", "이 달 발생분 대휴 사용", "대휴 제외 시간외", "특별휴가", "가장 빠른 만료"]) assert.ok(app.includes(text));
  assert.ok(types.includes("AnnualLeaveBalance"));
  assert.ok(types.includes("CompTimeCredit"));
  assert.ok(sql.includes("(v_work_date + time '09:00') at time zone 'Asia/Seoul'"));
  assert.ok(sql.includes("(v_work_date + time '18:00') at time zone 'Asia/Seoul'"));
  assert.ok(sql.includes("'normal','','true'") || sql.includes("'normal','',true"));
  assert.ok(sql.includes("on conflict (employee_id,work_date) do update"));
  assert.ok(sql.includes("where attendance_records.deleted_at is not null"));
  assert.ok(sql.includes("create trigger allocate_comp_time_usage_without_negative_trigger"));
  assert.ok(sql.includes("set approved_minutes = approved_minutes"));
});

test("overtime uses eight actual work hours and rounds an exceeded half-hour upward", async () => {
  const app = await read("app/attendance-app.tsx");
  const sql = await read("supabase/fix_comp_time_recognition_rule.sql");
  const install = await read("supabase/install_current.sql");
  for (const text of [
    "least(240,60 + ceil((p_raw_minutes - 60) / 30.0)::integer * 30)",
    "60 + ceil((v_raw_minutes - 60) / 30.0)::integer * 30",
    "set clock_out_at = clock_out_at",
  ]) {
    assert.ok(sql.includes(text));
    assert.ok(install.includes(text));
  }
  assert.ok(app.includes("worked - 480"));
  assert.ok(app.includes("Math.ceil((raw - 60) / 30)"));
  assert.ok(app.includes("Math.ceil((rawMinutes - 60) / 30)"));
});

test("attendance applications are separated from clock correction requests", async () => {
  const app = await read("app/attendance-app.tsx");
  const css = await read("app/globals.css");
  for (const text of ["근태 신청 관리", "근태 신청 검토", "근태 신청 대기", "출퇴근 수정", "휴가와 대체휴무", "출장과 예외근무", "시간외근무", "퇴근기록 대기", "승인 대기", "새 근태 신청"]) assert.ok(app.includes(text));
  assert.ok(!app.includes("수정 요청 대기"));
  assert.ok(!app.includes("수정 요청 검토"));
  assert.ok(app.includes('request.request_type === "overtime") return formatMinutes(minutes)'));
  assert.ok(app.includes('requestType === "overtime" ? formatMinutes(calculatedMinutes)'));
  assert.ok(css.includes(".request-category-tabs"));
});

test("dashboard location count excludes records completed by an admin", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes('todayRows.filter((r) => ["location_review", "admin_review"].includes(r.attendance_status)).length'));
  assert.ok(app.includes('note: "미확인 기록만 표시"'));
  assert.ok(!app.includes('todayRows.filter((r) => !["inside", "not_checked"].includes(r.clock_in_location_status)).length'));
});

test("result attendance sheets omit raw location and leave request reasons", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes('const annualDetail = annualMinutes > 0 ? `${leaveUnitLabel(annualMinutes)} 사용` : ""'));
  assert.ok(app.includes('const specialLeaveDetail = specialLeaveMinutes > 0 ? `${specialLeave?.request_subtype || "특별휴가"} ${formatMinutes(specialLeaveMinutes)} 사용` : ""'));
  assert.ok(app.includes('overtimeDetail, emergencyDetail, compDetail, annualDetail, specialLeaveDetail, otherLeaveDetail, sickDetail, tripDetail].filter(Boolean)'));
  assert.ok(!app.includes('annual?.reason ? `, 사유: ${annual.reason}`'));
  assert.ok(!app.includes('tripDetail, record?.note || ""'));
  assert.ok(app.includes('record.clock_in_accuracy == null ? "" : `${record.clock_in_accuracy}m`'));
});

test("server routes send opaque Supabase secret keys only as API keys", async () => {
  const helper = await read("app/api/_lib/server-supabase.ts");
  const clockRoute = await read("app/api/clock-attendance/route.ts");
  assert.ok(helper.includes('secretKey.startsWith("sb_secret_")'));
  assert.ok(helper.includes('headers.get("authorization") === `Bearer ${secretKey}`'));
  assert.ok(helper.includes('headers.delete("authorization")'));
  assert.ok(clockRoute.includes('/rest/v1/rpc/clock_attendance_server_api'));
  assert.ok(clockRoute.includes('apikey: secretKey'));
  assert.ok(clockRoute.includes('Authorization: `Bearer ${secretKey}`'));
  assert.ok(clockRoute.includes('secretKey.startsWith("sb_secret_")'));
  assert.ok(!clockRoute.includes('rpc("clock_attendance"'));
  for (const route of [
    "app/api/clock-attendance/route.ts",
    "app/api/admin-create-employee/route.ts",
    "app/api/admin-reset-password/route.ts",
    "app/api/employee-login/route.ts",
  ]) {
    assert.ok((await read(route)).includes("createServerSupabaseClient"));
  }
});

test("clock permission errors expose the safe database reason", async () => {
  const app = await read("app/attendance-app.tsx");
  assert.ok(app.includes("출퇴근 저장 권한이 거부되었습니다"));
  assert.ok(app.includes("출퇴근 저장 기능을 Supabase API에서 찾지 못했습니다"));
  assert.ok(app.includes("서버 응답: ${detail}"));
});

test("missing overtime helper functions have a standalone repair", async () => {
  const sql = await read("supabase/fix_missing_overtime_functions.sql");
  assert.ok(sql.includes("calculate_raw_overtime_minutes"));
  assert.ok(sql.includes("recognized_overtime_minutes"));
  assert.ok(sql.includes("greatest(0,worked_minutes - 480)"));
  assert.ok(!sql.includes("declare\n  v_settings"));
  assert.ok(sql.includes("ceil((p_raw_minutes - 60) / 30.0)"));
  assert.ok(sql.includes("to authenticated, service_role"));
});
