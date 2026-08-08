import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

export async function POST(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const orgId = typeof body?.orgId === "string" ? body.orgId.trim() : "";
  const requestedEmail = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  const name = typeof body?.name === "string" ? body.name.trim() : "";
  const employeeNumber = typeof body?.employeeNumber === "string" ? body.employeeNumber.trim().toUpperCase() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (!orgId || requestedEmail && !/^\S+@\S+\.\S+$/.test(requestedEmail) || name.length < 2 || !/^[A-Z0-9-]{2,24}$/.test(employeeNumber) || password.length < 4) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const { data: organization } = await client.from("organizations").select("id,org_code").eq("id", orgId).eq("is_active", true).maybeSingle();
  if (!organization) return json({ ok: false, code: "ORGANIZATION_NOT_FOUND" }, 404);
  const { data: duplicateNumber } = await client.from("profiles").select("id").ilike("employee_number", employeeNumber).limit(1).maybeSingle();
  if (duplicateNumber) return json({ ok: false, code: "EMPLOYEE_NUMBER_EXISTS" }, 409);
  const email = requestedEmail || `org-admin-${organization.org_code.toLowerCase().replace(/[^a-z0-9-]/g, "-")}-${employeeNumber.toLowerCase()}@attendance.invalid`;
  const { data: created, error: createError } = await client.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { name, employee_number: employeeNumber, department: "기관관리", org_code: organization.org_code },
  });
  if (createError || !created.user) return json({ ok: false, code: "ORG_ADMIN_CREATE_FAILED" }, 409);
  const { error: profileError } = await client.from("profiles").upsert({
    id: created.user.id, email, name, employee_number: employeeNumber, department: "기관관리",
    org_id: orgId, role: "org_admin", is_active: true, can_view_reports: true,
  }, { onConflict: "id" });
  if (profileError) {
    await client.auth.admin.deleteUser(created.user.id);
    return json({ ok: false, code: "PROFILE_CREATE_FAILED" }, 500);
  }
  await client.from("attendance_audit_logs").insert({
    employee_id: created.user.id,
    action_type: "org_admin_account_created",
    changed_field: "org_admin_account",
    after_value: JSON.stringify({ name, employee_number: employeeNumber }),
    reason: "최고관리자가 기관관리자 계정을 만들었습니다.",
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: orgId,
  });
  return json({ ok: true, profile: { id: created.user.id, email, name, employee_number: employeeNumber, org_id: orgId, role: "org_admin" } }, 201);
}
