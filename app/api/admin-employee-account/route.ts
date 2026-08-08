import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { toSupabasePassword } from "../../../lib/auth-password";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
const validUserId = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

export async function PATCH(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (!["admin", "org_admin", "super_admin"].includes(actor.role)) return json({ ok: false, code: "ADMIN_REQUIRED" }, 403);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const userId = typeof body?.userId === "string" ? body.userId.trim() : "";
  const name = typeof body?.name === "string" ? body.name.trim() : "";
  const employeeNumber = typeof body?.employeeNumber === "string" ? body.employeeNumber.trim().toUpperCase() : "";
  const department = typeof body?.department === "string" ? body.department.trim() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (!validUserId(userId) || name.length < 2 || name.length > 30 || !/^[A-Z0-9-]{2,30}$/.test(employeeNumber) || department.length > 50 || (password && password.length < 4)) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }

  const { data: target } = await client.from("profiles").select("id,name,employee_number,department,org_id,role").eq("id", userId).maybeSingle();
  if (!target || target.role !== "employee") return json({ ok: false, code: "EMPLOYEE_NOT_FOUND" }, 404);
  if (actor.role !== "super_admin" && actor.org_id !== target.org_id) return json({ ok: false, code: "ORGANIZATION_ACCESS_DENIED" }, 403);

  const { data: duplicate } = await client.from("profiles").select("id").eq("role", "employee").ilike("employee_number", employeeNumber).neq("id", userId).limit(1);
  if (duplicate?.length) return json({ ok: false, code: "EMPLOYEE_NUMBER_EXISTS" }, 409);

  const { data: authTarget, error: authReadError } = await client.auth.admin.getUserById(userId);
  if (authReadError || !authTarget.user) return json({ ok: false, code: "AUTH_ACCOUNT_NOT_FOUND" }, 404);
  const authChanges = {
    user_metadata: { ...authTarget.user.user_metadata, name, employee_number: employeeNumber, department },
    ...(password ? { password: toSupabasePassword(password) } : {}),
  };
  const { error: authUpdateError } = await client.auth.admin.updateUserById(userId, authChanges);
  if (authUpdateError) return json({ ok: false, code: password ? "AUTH_PASSWORD_UPDATE_FAILED" : "AUTH_ACCOUNT_UPDATE_FAILED" }, 409);

  const { data: profile, error: profileError } = await client.from("profiles").update({ name, employee_number: employeeNumber, department }).eq("id", userId).eq("role", "employee").select("*").maybeSingle();
  if (profileError || !profile) {
    await client.auth.admin.updateUserById(userId, { user_metadata: authTarget.user.user_metadata });
    const duplicateNumber = profileError?.code === "23505";
    return json({ ok: false, code: duplicateNumber ? "EMPLOYEE_NUMBER_EXISTS" : "PROFILE_UPDATE_FAILED" }, duplicateNumber ? 409 : 500);
  }

  await client.from("attendance_audit_logs").insert({
    employee_id: userId,
    action_type: "employee_account_updated",
    changed_field: "employee_profile",
    before_value: JSON.stringify({ name: target.name, employee_number: target.employee_number, department: target.department }),
    after_value: JSON.stringify({ name, employee_number: employeeNumber, department }),
    reason: "직원 정보 수정",
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: target.org_id,
  });
  return json({ ok: true, profile, passwordChanged: Boolean(password) });
}
