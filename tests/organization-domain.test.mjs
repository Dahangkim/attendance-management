import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);

test("multiorganization foundation migrates existing records without fixing a future organization chart", async () => {
  const sql = await readFile(new URL("supabase/upgrade_multi_org_foundation.sql", root), "utf8");
  assert.match(sql, /create table if not exists public\.organizations/);
  assert.match(sql, /domain text/);
  assert.match(sql, /'sample-org', '샘플 기관', '기관', 'facility', null, null/);
  assert.doesNotMatch(sql, /'bulteok'/);
  assert.doesNotMatch(sql, /'banjjak'/);
  assert.match(sql, /where org_code = 'sample-org'/);
  assert.doesNotMatch(sql, /drop column if exists id/);
  assert.doesNotMatch(sql, /create or replace function public\.clock_attendance\(/);
});

test("branding is centralized and resolved from each organization", async () => {
  const branding = await readFile(new URL("lib/organization-branding.ts", root), "utf8");
  const deploymentBranding = await readFile(new URL("lib/deployment-branding.ts", root), "utf8");
  const migration = await readFile(new URL("supabase/upgrade_multi_org_branding.sql", root), "utf8");
  const layout = await readFile(new URL("app/layout.tsx", root), "utf8");
  const manifest = await readFile(new URL("app/api/manifest/route.ts", root), "utf8");
  assert.match(branding, /brand_primary_color/);
  assert.match(branding, /brand_logo_url/);
  assert.match(migration, /alter table public\.organizations add column if not exists brand_title/);
  assert.match(migration, /short_name \|\| ' 근태관리'/);
  assert.match(layout, /getRequestBranding/);
  assert.match(layout, /brand\.title/);
  assert.match(manifest, /organizationBranding/);
  assert.match(deploymentBranding, /NEXT_PUBLIC_APP_ORGANIZATION_NAME/);
  assert.match(deploymentBranding, /NEXT_PUBLIC_APP_TITLE/);
  assert.doesNotMatch(deploymentBranding, /실제 기관명/);
});

test("deployment branding is used when a host is not assigned to an organization", async () => {
  const requestBranding = await readFile(new URL("app/_lib/request-branding.ts", root), "utf8");
  const manifest = await readFile(new URL("app/api/manifest/route.ts", root), "utf8");
  const icon = await readFile(new URL("app/api/brand-icon/route.ts", root), "utf8");
  const context = await readFile(new URL("app/api/_lib/organization-context.ts", root), "utf8");
  assert.match(requestBranding, /organization \|\| deploymentBrandingSource\(\)/);
  assert.match(manifest, /organization \|\| deploymentBrandingSource\(\)/);
  assert.match(icon, /organization \|\| deploymentBrandingSource\(\)/);
  assert.doesNotMatch(context, /LOCAL_HOSTS|\? "sample"/);
});

test("administrator sidebar uses the configurable short mark without adding employee avatar settings", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const styles = await readFile(new URL("app/globals.css", root), "utf8");
  assert.match(app, /isAdminRole\(effectiveRole\) && <div className="avatar">\{tenantBranding\.mark\}<\/div>/);
  assert.doesNotMatch(app, /currentProfile\?\.name\.slice\(0, 1\).*sidebar-user/);
  assert.match(styles, /\.avatar \{ width: auto; min-width: 38px;/);
});

test("role types include organization administrators", async () => {
  const types = await readFile(new URL("lib/types.ts", root), "utf8");
  assert.match(types, /"team_lead"/);
  assert.match(types, /"org_admin"/);
  assert.match(types, /org_id\?: string/);
});

test("employee login resolves the organization from a globally unique employee number", async () => {
  const route = await readFile(new URL("app/api/employee-login/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /\.ilike\("employee_number", employeeNumber\)/);
  assert.match(route, /\.eq\("id", profile\.org_id\)/);
  assert.match(app, /사번 또는 최고관리자 이메일/);
  assert.match(app, /소속 기관과 권한을 자동으로 확인/);
  assert.match(app, /기관별 접속 도메인, 선택/);
});

test("employee creation assigns organization on the server", async () => {
  const route = await readFile(new URL("app/api/admin-create-employee/route.ts", root), "utf8");
  const repair = await readFile(new URL("supabase/repair_profile_employee_number_global_unique.sql", root), "utf8");
  assert.match(route, /new Set\(\["admin", "org_admin"\]\)/);
  assert.match(route, /const targetOrgId = actor\.org_id/);
  assert.doesNotMatch(route, /team_lead/);
  assert.doesNotMatch(route, /actor\.role === "super_admin"/);
  assert.match(route, /org_code: organization\.org_code/);
  assert.match(route, /org_id: organization\.id/);
  assert.match(route, /next_employee_number/);
  assert.match(route, /organization\.org_code.*employeeNumber\.toLowerCase/);
  assert.match(repair, /profiles_employee_number_global_unique_idx/);
  assert.match(repair, /upper\(employee_number\)/);
  assert.match(repair, /Asia\/Seoul/);
});

test("employee numbers can be edited without replacing historical employee identity", async () => {
  const route = await readFile(new URL("app/api/admin-employee-account/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /\.eq\("role", "employee"\)\.ilike\("employee_number", employeeNumber\)/);
  assert.match(route, /\.update\(\{ name, employee_number: employeeNumber, department \}\)/);
  assert.doesNotMatch(route, /deleteUser/);
  assert.match(app, /EmployeeEditModal/);
  assert.match(app, /기존 근태기록은 그대로 유지/);
});

test("organization administrator edits skip redundant auth email changes", async () => {
  const route = await readFile(new URL("app/api/admin-org-admin-account/route.ts", root), "utf8");
  assert.match(route, /email !== currentAuthEmail/);
  assert.match(route, /if \(email !== currentAuthEmail\)/);
  assert.match(route, /if \(password\)/);
  assert.match(route, /admin\.listUsers/);
  assert.match(route, /duplicateAuthUser/);
  assert.match(route, /EMAIL_ALREADY_EXISTS/);
  assert.match(route, /INVALID_EMAIL/);
});

test("organization administrators can complete attendance confirmation in their own organization", async () => {
  const repair = await readFile(new URL("supabase/repair_admin_confirm_attendance_org_admin.sql", root), "utf8");
  assert.match(repair, /'admin','org_admin','super_admin'/);
  assert.match(repair, /v_record\.org_id is distinct from v_org_id/);
  assert.match(repair, /v_record\.org_id/);
});

test("employees and organization administrators can record emergency support work", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const sql = await readFile(new URL("supabase/upgrade_emergency_support_work.sql", root), "utf8");
  const liveSql = await readFile(new URL("supabase/repair_emergency_support_live_tracking.sql", root), "utf8");
  const editSql = await readFile(new URL("supabase/repair_emergency_support_cancel_and_edit.sql", root), "utf8");
  assert.match(app, /EmployeeEmergencySupportModal/);
  assert.match(app, /EmergencySupportWorkModal/);
  assert.match(app, /review_emergency_support_work/);
  assert.match(app, /admin_create_emergency_support_work/);
  assert.match(app, /data\.getAll\("employee_id"\)/);
  assert.match(app, /selectedEmployees\.length/);
  assert.match(app, /type="checkbox" name="employee_id"/);
  assert.match(sql, /'emergency_support'/);
  assert.match(sql, /'admin','org_admin','super_admin'/);
  assert.match(sql, /v_request\.org_id is distinct from v_org_id/);
  assert.match(sql, /v_minutes > 1440/);
  assert.match(app, /start_emergency_support_work/);
  assert.match(app, /finish_emergency_support_work/);
  assert.match(app, /긴급지원 종료/);
  assert.match(liveSql, /EMERGENCY_SUPPORT_NOT_FINISHED/);
  assert.match(liveSql, /CLOCK_OUT_REQUIRED/);
  assert.match(editSql, /employee_cancel_emergency_support_work/);
  assert.match(editSql, /update_emergency_support_work/);
  assert.match(editSql, /emergency_support_cancelled/);
  assert.match(editSql, /p_decision = 'approved'/);
});

test("organization administrators manage leave balances only inside their organization", async () => {
  const repair = await readFile(new URL("supabase/repair_org_admin_leave_balance_management.sql", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  for (const fn of ["admin_save_annual_leave_entitlement", "admin_delete_annual_leave_entitlement", "admin_add_comp_time_credit", "admin_extend_comp_time_credit"]) {
    assert.match(repair, new RegExp(`create or replace function public\\.${fn}`));
  }
  assert.match(repair, /'admin','org_admin','super_admin'/);
  assert.match(repair, /ORGANIZATION_ACCESS_DENIED/);
  assert.match(repair, /v_employee_org_id is distinct from v_actor_org_id/);
  assert.match(repair, /changed_by_role,org_id/);
  assert.match(app, /className="modal wide-modal workflow-modal"/);
  assert.match(app, /1\. 직원 선택/);
  assert.match(app, /적용 기간과 부여 일수를 한 번에 입력/);
});

test("organization settings keep save actions with their sections and hide raw logo urls", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(app, /1\. 기본 근무시간/);
  assert.match(app, /기본 근무시간 저장/);
  assert.match(app, /name="brand_logo_url" type="hidden"/);
  assert.doesNotMatch(app, />로고 주소<input/);
});

test("each organization can hide new emergency support actions without deleting history", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const types = await readFile(new URL("lib/types.ts", root), "utf8");
  const migration = await readFile(new URL("supabase/add_emergency_support_feature_toggle.sql", root), "utf8");
  assert.match(types, /emergency_support_enabled: boolean/);
  assert.match(app, /긴급지원 근무 사용/);
  assert.match(app, /꺼도 기존 기록은 보존됩니다/);
  assert.match(app, /emergencySupportEnabled \&\& <button className="primary-button compact"/);
  assert.match(app, /emergencySupportEnabled \|\| activeEmergencyRequest/);
  assert.match(app, /error\.code === "PGRST202"/);
  assert.match(app, /긴급지원 설정은 데이터베이스 SQL 적용 후 사용할 수 있습니다/);
  assert.match(migration, /add column if not exists emergency_support_enabled boolean not null default true/);
  assert.match(migration, /EMERGENCY_SUPPORT_DISABLED/);
  assert.match(migration, /before insert on public\.correction_requests/);
  assert.match(migration, /where org_id = v_org_id/);
});

test("organization administrators restore attendance and manage exceptions only in their organization", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const repair = await readFile(new URL("supabase/repair_org_admin_restore_and_exceptions.sql", root), "utf8");
  for (const fn of ["admin_restore_attendance", "admin_create_attendance_exception", "admin_create_attendance_exceptions", "admin_cancel_attendance_exception"]) {
    assert.match(repair, new RegExp(`create or replace function public\\.${fn}`));
  }
  assert.match(repair, /'admin','org_admin','super_admin'/);
  assert.match(repair, /ORGANIZATION_ACCESS_DENIED/);
  assert.match(repair, /v_record\.org_id is distinct from v_org_id/);
  assert.match(repair, /v_item\.org_id is distinct from v_org_id/);
  assert.match(app, /기관별 근무조건 저장/);
  assert.match(app, /const categories = emergencySupportEnabled/);
  assert.doesNotMatch(app, /긴급지원 설정 저장/);
});

test("all employee-scoped tables receive organization isolation", async () => {
  const sql = await readFile(new URL("supabase/upgrade_multi_org_isolation.sql", root), "utf8");
  for (const table of ["employee_schedule_overrides", "attendance_locations", "location_consents", "attendance_events", "attendance_exceptions", "comp_time_credits", "comp_time_usage_allocations", "annual_leave_entitlements"]) {
    assert.match(sql, new RegExp(`alter table public\\.${table} add column if not exists org_id`));
    assert.match(sql, new RegExp(`alter table public\\.${table} alter column org_id set not null`));
  }
  assert.match(sql, /org_id = public\.current_profile_org_id\(\)/);
  assert.match(sql, /employee_id = auth\.uid\(\) or public\.is_super_admin\(\)/);
});

test("organization governance separates institution, administrator, and employee creation", async () => {
  const organizations = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const orgAdmin = await readFile(new URL("app/api/admin-create-org-admin/route.ts", root), "utf8");
  const employee = await readFile(new URL("app/api/admin-create-employee/route.ts", root), "utf8");
  const changes = await readFile(new URL("app/api/organization-change-requests/route.ts", root), "utf8");
  const reviews = await readFile(new URL("app/api/admin-review-organization-change/route.ts", root), "utf8");
  assert.match(organizations, /actor\.role !== "super_admin"/);
  assert.match(orgAdmin, /role: "org_admin"/);
  assert.match(employee, /new Set\(\["admin", "org_admin"\]\)/);
  assert.match(changes, /"workplace_location", "office_ip", "org_admin_account"/);
  assert.match(reviews, /decision === "approved"/);
});

test("super administrators create and select organizations from the application", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const organizationsRoute = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const route = await readFile(new URL("app/api/admin-organization-attendance/route.ts", root), "utf8");
  assert.match(app, /OrganizationManagement/);
  assert.match(app, /loadOrganizations/);
  assert.match(app, /createOrganization/);
  assert.match(app, /createOrganizationAdmin/);
  assert.match(app, /organizationAdmins/);
  assert.match(app, /등록된 기관관리자/);
  assert.match(app, /관리자 목록/);
  assert.match(organizationsRoute, /organizationAdmins/);
  assert.match(organizationsRoute, /\.eq\("role", "org_admin"\)/);
  assert.match(app, /조회 기관/);
  assert.match(app, /if \(userProfile\.role === "super_admin"\)/);
  assert.match(app, /setRecords\(\[\]\)/);
  assert.match(app, /admin-organization-attendance\?orgId=/);
  assert.match(route, /actor\.role !== "super_admin"/);
  for (const table of ["attendance_records", "correction_requests", "attendance_exceptions", "attendance_audit_logs", "monthly_closings"]) {
    assert.match(route, new RegExp(`from\\("${table}"\\).*eq\\("org_id", orgId\\)`));
  }
  assert.doesNotMatch(route, /attendance_records_view/);
});

test("organization administrators load audit history through an organization-checked server route", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const route = await readFile(new URL("app/api/admin-organization-attendance/route.ts", root), "utf8");
  assert.match(app, /effectiveRole === "super_admin" \? selectedOrgId : currentProfile\?\.org_id \|\| ""/);
  assert.match(route, /actor\.role !== "super_admin" && actor\.org_id !== orgId/);
  assert.match(route, /ORGANIZATION_ACCESS_DENIED/);
  assert.match(route, /actor\.role === "super_admin"\s*\? await client\.from\("attendance_audit_logs"\)/);
});

test("super administrator branding and organization administrator accounts are managed independently", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const route = await readFile(new URL("app/api/admin-org-admin-account/route.ts", root), "utf8");
  assert.match(app, /SUPER_ADMIN_BRANDING/);
  assert.match(app, /effectiveRole === "super_admin" \? superAdminBranding/);
  assert.match(app, /통합관리 독립 기능/);
  assert.match(app, /기관을 선택해도 이 영역의 색상과 입력값은 바뀌지 않습니다/);
  assert.match(app, /최고관리자 직접 변경/);
  assert.match(app, /관리자 정보 저장/);
  assert.match(app, /계정 삭제/);
  assert.match(route, /actor\.role !== "super_admin"/);
  assert.match(route, /export async function PATCH/);
  assert.match(route, /export async function DELETE/);
  assert.match(route, /ban_duration: "876000h"/);
  assert.match(route, /retainedRecords: true/);
});

test("each organization can configure fixed, flexible, shift, and overnight work", async () => {
  const sql = await readFile(new URL("supabase/upgrade_org_governance_and_work_policies.sql", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  for (const text of ["organization_work_policies", "work_shift_templates", "employee_shift_assignments", "attendance_mode in ('fixed', 'flexible', 'shift')", "crosses_midnight", "work_date_boundary_time", "max_open_shift_hours"]) {
    assert.match(sql, new RegExp(text.replace(/[()]/g, "\\$&")));
  }
  assert.match(sql, /IP_CHANGE_APPROVAL_REQUIRED/);
  assert.match(sql, /unique \(org_id, year, month\)/);
  assert.match(app, /policy\.attendance_mode === "shift"/);
  assert.match(app, /고정 근무에서는 기관의 기본 근무시간을 사용하므로 근무조와 근무표를 따로 만들지 않습니다/);
  assert.match(app, /현재 위치 자동입력/);
  assert.match(app, /현재 IP 자동입력/);
});

test("super administrators edit and safely deactivate organizations", async () => {
  const route = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  for (const text of ["export async function PATCH", "export async function DELETE", "retainedRecords: true", "scope === \"status\"", "기관 정보 저장", "기관 사용 중지", "기관 다시 사용", "기존 근태기록은 보존"]) {
    assert.ok(route.includes(text) || app.includes(text));
  }
});

test("browser sessions expire with the window while installed apps stay signed in", async () => {
  const client = await readFile(new URL("lib/supabase.ts", root), "utf8");
  assert.match(client, /display-mode: standalone/);
  assert.match(client, /installed \? window\.localStorage : window\.sessionStorage/);
  assert.match(client, /storage: installedAppStorage\(\)/);
});

test("organization administrators can edit branding without changing organization governance", async () => {
  const route = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const uploadRoute = await readFile(new URL("app/api/admin-upload-brand-logo/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /scope === "branding"/);
  assert.match(route, /orgId !== actor\.org_id/);
  assert.match(app, /기관 화면과 로고/);
  assert.match(app, /기관 공식명, 도메인과 기관 사용 중지는 최고관리자가 관리합니다/);
  assert.match(app, /updateOrganizationBranding/);
  assert.match(app, /기본 색상으로 되돌리기/);
  assert.match(app, /로고 파일/);
  assert.match(uploadRoute, /organization-branding/);
  assert.match(uploadRoute, /MAX_FILE_SIZE/);
  assert.match(uploadRoute, /brand_logo_url/);
});

test("work policy repair is safe to reapply without changing attendance history", async () => {
  const sql = await readFile(new URL("supabase/repair_organization_work_policy_save.sql", root), "utf8");
  assert.match(sql, /create table if not exists public\.organization_work_policies/);
  assert.match(sql, /drop policy if exists "organization admin manages work policy"/);
  assert.match(sql, /grant select, insert, update, delete/);
  assert.doesNotMatch(sql, /update public\.attendance_records/);
  assert.doesNotMatch(sql, /delete from public\.attendance_records/);
});

test("public distribution keeps the maintainer contact visible and configurable", async () => {
  const owner = await readFile(new URL("lib/application-owner.ts", root), "utf8");
  const env = await readFile(new URL(".env.example", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(owner, /NEXT_PUBLIC_APP_OWNER_NAME/);
  assert.match(owner, /NEXT_PUBLIC_MAINTAINER_EMAIL/);
  assert.match(env, /NEXT_PUBLIC_MAINTAINER_EMAIL=indigoblau1223@gmail\.com/);
  assert.match(app, /mailto:\$\{applicationOwner\.maintainerEmail\}/);
  assert.doesNotMatch(app, />수정 요청 메일 보내기</);
  assert.doesNotMatch(app, /수정 요청 이메일은 배포 설정에서 등록합니다/);
  assert.match(app, /readableTextColor/);
});

test("public release checklist requires repository synchronization and hardcoding review", async () => {
  const checklist = await readFile(new URL("PUBLIC_RELEASE_CHECKLIST.md", root), "utf8");
  for (const text of ["두 저장소의 동기화 방식", "운영환경에 자동 배포하지 않고", "기관 고유정보 제거", "근무지 주소와 GPS 좌표", "공개 배포용 초기 설치 SQL", "Git 전체 이력", "공개 배포용 새 Supabase"]) {
    assert.match(checklist, new RegExp(text));
  }
});

test("organization administrators delete attendance only inside their organization", async () => {
  const sql = await readFile(new URL("supabase/repair_org_admin_attendance_delete.sql", root), "utf8");
  assert.match(sql, /'admin','org_admin','super_admin'/);
  assert.match(sql, /current_profile_org_id/);
  assert.match(sql, /v_record\.org_id is distinct from v_org_id/);
  assert.match(sql, /MONTH_CLOSED/);
  assert.match(sql, /v_record\.org_id/);
});

test("employee number changes keep login connected to the existing auth account", async () => {
  const route = await readFile(new URL("app/api/employee-login/route.ts", root), "utf8");
  assert.match(route, /getUserById\(profile\.id\)/);
  assert.match(route, /const authEmail = authUserData\.user\?\.email/);
  assert.match(route, /signInWithPassword\(\{ email: authEmail, password: toSupabasePassword\(password\) \}\)/);
});

test("super administrators can edit employee numbers for the selected organization", async () => {
  const route = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /organizationEmployees/);
  assert.match(route, /\.eq\("role", "employee"\)/);
  assert.match(app, /selectedEmployees/);
  assert.match(app, /사번과 정보 수정/);
  assert.match(app, /onEditEmployee/);
});

test("super administrator basic information is distinct from organization operation settings", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(app, /최고관리자 관리 항목/);
  assert.match(app, /화면 제목, 로고와 색상은 각 기관관리자/);
  assert.match(app, /balance-section-tabs/);
  assert.match(app, /직원별 잔액/);
  assert.match(app, /연차 부여/);
  assert.match(app, /대휴 적립/);
});

test("leave section headings are padded inside clipped table cards", async () => {
  const css = await readFile(new URL("app/globals.css", root), "utf8");
  assert.match(css, /\.table-card > \.section-heading \{ padding:/);
});

test("signed-in organization branding reloads from the profile organization", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(app, /brand_description,brand_subtitle,brand_mark,brand_logo_url/);
  assert.match(app, /setTenantOrganization\(organization as TenantOrganization\)/);
});

test("super administrators keep independent persisted branding", async () => {
  const sql = await readFile(new URL("supabase/upgrade_super_admin_branding.sql", root), "utf8");
  const route = await readFile(new URL("app/api/admin-super-admin-branding/route.ts", root), "utf8");
  const upload = await readFile(new URL("app/api/admin-upload-brand-logo/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(sql, /profiles add column if not exists brand_logo_url/);
  assert.match(route, /actor\.role !== "super_admin"/);
  assert.match(upload, /scope === "super_admin"/);
  assert.match(app, /내 화면 설정/);
  assert.match(app, /updateSuperAdminBranding/);
});

test("super administrators can set their own globally unique employee number", async () => {
  const route = await readFile(new URL("app/api/admin-super-admin-account/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /actor\.role !== "super_admin"/);
  assert.match(route, /\.ilike\("employee_number", employeeNumber\)\.neq\("id", actor\.id\)/);
  assert.match(route, /super_admin_employee_number_updated/);
  assert.match(app, /최고관리자 사번 저장/);
  assert.match(app, /admin-super-admin-account/);
});

test("holiday work uses each organization's settings and becomes overtime", async () => {
  const sql = await readFile(new URL("supabase/repair_multi_org_holiday_overtime.sql", root), "utf8");
  const types = await readFile(new URL("lib/types.ts", root), "utf8");
  assert.match(sql, /where org_id = new\.org_id/);
  assert.match(sql, /when v_is_holiday then v_actual/);
  assert.match(sql, /where org_id = p_record\.org_id/);
  assert.match(sql, /set clock_out_at = clock_out_at,\s+overtime_status = case when overtime_status = 'approved'/);
  assert.match(sql, /holiday_work_counts_as_overtime/);
  assert.match(types, /holiday_work: "휴일 시간외근무"/);
});

test("disabled organizations remain readable and super administrator audit categories stay distinct", async () => {
  const route = await readFile(new URL("app/api/admin-organization-attendance/route.ts", root), "utf8");
  const organizations = await readFile(new URL("app/api/admin-organizations/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.doesNotMatch(route, /eq\("id", orgId\)\.eq\("is_active", true\)/);
  assert.match(route, /changed_by_role", "super_admin"/);
  assert.match(organizations, /organization_deactivated/);
  assert.match(organizations, /attendance_audit_logs/);
  assert.match(app, /최고관리자 직접 변경/);
  assert.match(app, /governanceActions/);
});

test("organization administrators can reopen emergency work and retention cleanup keeps recent years", async () => {
  const sql = await readFile(new URL("supabase/repair_review_audit_and_retention.sql", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(sql, /'admin','org_admin','super_admin'/);
  assert.match(sql, /v_request\.org_id is distinct from v_org_id/);
  assert.match(sql, /correction_request_id, org_id/);
  assert.match(sql, /current_profile_role\(\).*SUPER_ADMIN_REQUIRED/s);
  assert.match(sql, /- 7/);
  assert.match(sql, /CONFIRMATION_REQUIRED/);
  assert.match(app, /preview_attendance_retention_cleanup/);
  assert.match(app, /5년 경과 기록 삭제/);
  assert.match(app, /코드를 다시 고칠 필요가 없습니다/);
  assert.match(app, /Math\.max\(record\.raw_overtime_minutes \|\| 0, recordedMinutes\)/);
});

test("organization change approvals are monthly and can return to review", async () => {
  const route = await readFile(new URL("app/api/organization-change-requests/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(route, /export async function PATCH/);
  assert.match(route, /organization_change_reopened/);
  assert.match(route, /status: "pending"/);
  assert.match(app, /reopenOrganizationChange/);
  assert.match(app, /requestMonth/);
  assert.match(app, /처리 완료 건도 재검토/);
});

test("emergency support stays separate from attendance and overtime review first returns to pending", async () => {
  const sql = await readFile(new URL("supabase/repair_emergency_attendance_and_overtime_reopen.sql", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(sql, /work_date = v_local::date/);
  assert.doesNotMatch(sql, /clock_out_at = greatest\(coalesce\(clock_out_at,v_end_at\),v_end_at\)/);
  assert.doesNotMatch(sql, /max\(\(end_date \+ end_time\) at time zone 'Asia\/Seoul'\)/);
  assert.match(sql, /EMERGENCY_SUPPORT_TIME_OVERLAP/);
  assert.match(sql, /admin_reopen_overtime_review/);
  assert.match(sql, /overtime_status = 'pending'/);
  assert.match(app, /approvedEmergencyMinutesForRecord/);
  assert.match(app, /effectiveClockOutAt/);
  assert.match(app, /requestType === "emergency_support" \? "emergency"/);
  assert.match(app, /일반 시간외근무/);
  assert.match(app, /긴급지원 인정시간/);
  assert.match(app, /onOvertimeReopen/);
  assert.match(app, /setStatusView\("pending"\)/);
});

test("organization administrators can add weekend attendance in their own organization", async () => {
  const sql = await readFile(new URL("supabase/repair_admin_manual_attendance_multi_org.sql", root), "utf8");
  assert.match(sql, /'admin','org_admin','super_admin'/);
  assert.match(sql, /v_employee_org_id is distinct from v_actor_org_id/);
  assert.match(sql, /org_id = v_employee_org_id/);
  assert.match(sql, /admin_create_attendance_records/);
});

test("super administrator self audit is not labeled as an organization", async () => {
  const account = await readFile(new URL("app/api/admin-super-admin-account/route.ts", root), "utf8");
  const branding = await readFile(new URL("app/api/admin-super-admin-branding/route.ts", root), "utf8");
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  assert.match(account, /org_id: null/);
  assert.match(branding, /org_id: null/);
  assert.match(app, /directScopeName/);
  assert.match(app, /"최고관리자"/);
});

test("organization administrators review overtime only inside their organization", async () => {
  const sql = await readFile(new URL("supabase/repair_org_admin_overtime_review.sql", root), "utf8");
  assert.match(sql, /'admin','org_admin','super_admin'/);
  assert.match(sql, /v_record\.org_id is distinct from v_org_id/);
  assert.match(sql, /source_date,org_id/);
  assert.match(sql, /correction_request_id,org_id/);
});

test("employee number login no longer aliases short passwords and keeps case-insensitive numbers", async () => {
  const route = await readFile(new URL("app/api/employee-login/route.ts", root), "utf8");
  const password = await readFile(new URL("lib/auth-password.ts", root), "utf8");
  assert.match(route, /password\.length < 1/);
  assert.match(route, /\.ilike\("employee_number", employeeNumber\)/);
  assert.match(route, /toSupabasePassword\(password\)/);
  assert.match(route, /profile\.must_change_password && password\.length >= 4 && password\.length < 6/);
  assert.match(password, /return password;/);
  assert.doesNotMatch(password, /attendance:/);
  assert.doesNotMatch(route, /!profiles\[0\]\.email/);
});

test("secure clock uses organization holidays and keeps generated PC diagnostics out of notes", async () => {
  const sql = await readFile(new URL("supabase/upgrade_secure_clock_and_overnight.sql", root), "utf8");
  assert.match(sql, /public\.organization_holidays where org_id = v_user\.org_id and holiday_date = v_work_date/);
  assert.match(sql, /사무실 PC에서 기록, 위치 측정 오차/);
  assert.match(sql, /v_record_note/);
  assert.match(sql, /update public\.attendance_records\s+set note = trim\(regexp_replace/);
});

test("security hardening isolates settings, closings, workplaces, and organization holidays", async () => {
  const sql = await readFile(new URL("supabase/security_hardening_multi_org.sql", root), "utf8");
  for (const table of ["organization_holidays", "workplaces", "organization_settings", "monthly_closings"]) assert.match(sql, new RegExp(table));
  assert.match(sql, /org_id = public\.current_profile_org_id\(\)/);
  assert.match(sql, /where org_id = v_org_id and is_active/);
  assert.doesNotMatch(sql, /where is_active = true\s+returning/);
  assert.match(sql, /primary key \(org_id, holiday_date\)/);
  assert.match(sql, /super admin manages statutory holidays/);
  assert.match(sql, /update public\.profiles set must_change_password = true where is_active/);
  assert.match(sql, /complete_required_password_change/);
  assert.match(sql, /admin_set_report_viewer/);
  assert.match(sql, /v_role not in \('admin','org_admin','super_admin'\)/);
  assert.match(sql, /org_id = v_employee\.org_id/);
  assert.match(sql, /changed_by_role, org_id/);
});

test("fresh installs enforce emergency support and protected workplace approval", async () => {
  const install = await readFile(new URL("supabase/install_current.sql", root), "utf8");
  const repair = await readFile(new URL("supabase/repair_protected_workplace_approval_only.sql", root), "utf8");
  assert.match(install, /p_emergency_support_enabled boolean/);
  assert.match(install, /create trigger enforce_emergency_support_feature_toggle before insert/);
  assert.match(install, /EMERGENCY_SUPPORT_DISABLED/);
  assert.match(install, /revoke all on function public\.save_workplace_settings[^;]+authenticated/);
  assert.match(repair, /revoke insert, update, delete on public\.workplaces from authenticated/);
  assert.match(repair, /revoke insert, update, delete on public\.organization_settings from authenticated/);
});

test("only public developer support is exposed and institution support stays offline", async () => {
  const app = await readFile(new URL("app/attendance-app.tsx", root), "utf8");
  const owner = await readFile(new URL("lib/application-owner.ts", root), "utf8");
  const context = await readFile(new URL("app/api/_lib/organization-context.ts", root), "utf8");
  const login = await readFile(new URL("app/api/employee-login/route.ts", root), "utf8");
  assert.match(owner, /NEXT_PUBLIC_MAINTAINER_EMAIL/);
  assert.match(app, /이름, 사번, 근태기록 등 개인정보를 보내지 마세요/);
  assert.match(app, /근태기록, 신청, 로그인과 계정 문의는 소속 기관 관리자에게 문의하세요/);
  assert.match(app, /isAdminRole\(effectiveRole\) \? <SupportContact compact \/> : <InstitutionSupportNotice compact \/>/);
  assert.match(app, /8자 이상으로 영문, 숫자, 특수문자를 각각 1개 이상 포함/);
  assert.match(app, /6자 이상으로 설정해 주세요/);
  assert.doesNotMatch(app, /support_email|supportEmail/);
  assert.doesNotMatch(context, /support_email/);
  assert.doesNotMatch(login, /support_email/);
});
