import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { toSupabasePassword } from "../../../lib/auth-password";

export const dynamic = "force-dynamic";

const json = (body: Record<string, unknown>, status: number) => Response.json(body, {
  status,
  headers: { "Cache-Control": "no-store" },
});

export async function POST(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !secretKey) return json({ ok: false, code: "CREATE_NOT_CONFIGURED" }, 503);

  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);
  const body = await request.json().catch(() => null) as { name?: unknown; department?: unknown; password?: unknown } | null;
  const name = typeof body?.name === "string" ? body.name.trim() : "";
  const department = typeof body?.department === "string" ? body.department.trim() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (name.length < 2 || name.length > 30 || department.length > 50 || password.length < 6) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }

  const adminClient = createServerSupabaseClient(supabaseUrl, secretKey);
  const { data: authData, error: authError } = await adminClient.auth.getUser(token);
  if (authError || !authData.user) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);
  const { data: actor } = await adminClient.from("profiles").select("id,role,is_active,org_id").eq("id", authData.user.id).maybeSingle();
  const allowedRoles = new Set(["admin", "org_admin"]);
  if (!actor?.is_active || !allowedRoles.has(actor.role)) return json({ ok: false, code: "ADMIN_REQUIRED" }, 403);

  const targetOrgId = actor.org_id;
  if (!targetOrgId) return json({ ok: false, code: "ORGANIZATION_REQUIRED" }, 400);
  const { data: organization } = await adminClient.from("organizations")
    .select("id,org_code,org_name,short_name")
    .eq("id", targetOrgId)
    .eq("organization_type", "facility")
    .eq("is_active", true)
    .maybeSingle();
  if (!organization) return json({ ok: false, code: "ORGANIZATION_NOT_FOUND" }, 404);

  const { data: employeeNumberData, error: employeeNumberError } = await adminClient.rpc("next_employee_number");
  const employeeNumber = typeof employeeNumberData === "string" ? employeeNumberData : "";
  if (employeeNumberError || !/^\d{6}$/.test(employeeNumber)) return json({ ok: false, code: "EMPLOYEE_NUMBER_CREATE_FAILED" }, 500);
  const email = `${organization.org_code}.${employeeNumber.toLowerCase()}@attendance.invalid`;
  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password: toSupabasePassword(password),
    email_confirm: true,
    user_metadata: { name, employee_number: employeeNumber, department, org_code: organization.org_code },
  });
  if (createError || !created.user) {
    const duplicate = /already|registered|exists/i.test(createError?.message || "");
    return json({ ok: false, code: duplicate ? "EMPLOYEE_ALREADY_EXISTS" : "EMPLOYEE_CREATE_FAILED" }, duplicate ? 409 : 500);
  }

  const { error: profileError } = await adminClient.from("profiles").upsert({
    id: created.user.id,
    email,
    name,
    employee_number: employeeNumber,
    department,
    org_id: organization.id,
    role: "employee",
    is_active: true,
    can_view_reports: false,
  }, { onConflict: "id" });
  if (profileError) {
    await adminClient.auth.admin.deleteUser(created.user.id);
    return json({ ok: false, code: "PROFILE_CREATE_FAILED" }, 500);
  }

  await adminClient.from("attendance_audit_logs").insert({
    employee_id: created.user.id,
    action_type: "employee_created",
    changed_field: "employee_account",
    before_value: "없음",
    after_value: `${name} (${employeeNumber})`,
    reason: "신규 직원 계정 생성",
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: organization.id,
  });
  return json({ ok: true, organization, profile: { id: created.user.id, email, name, employee_number: employeeNumber, department, org_id: organization.id, role: "employee", is_active: true, can_view_reports: false } }, 200);
}
