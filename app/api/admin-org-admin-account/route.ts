import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";

const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
const validUserId = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

async function context(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return { client: null, actor: null, error: json({ ok: false, code: "NOT_CONFIGURED" }, 503) };
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return { client: null, actor: null, error: json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403) };
  if (actor.role !== "super_admin") return { client: null, actor: null, error: json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403) };
  return { client, actor, error: null };
}

export async function PATCH(request: Request) {
  const { client, actor, error: contextError } = await context(request);
  if (!client) return contextError as Response;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const userId = typeof body?.userId === "string" ? body.userId.trim() : "";
  const name = typeof body?.name === "string" ? body.name.trim() : "";
  const employeeNumber = typeof body?.employeeNumber === "string" ? body.employeeNumber.trim().toUpperCase() : "";
  const requestedEmail = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  const department = typeof body?.department === "string" ? body.department.trim() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (!validUserId(userId) || name.length < 2 || name.length > 30 || !/^[A-Z0-9-]{2,24}$/.test(employeeNumber) || requestedEmail && !/^\S+@\S+\.\S+$/.test(requestedEmail) || department.length > 50 || (password && password.length < 4)) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }

  const { data: target } = await client.from("profiles")
    .select("id,email,name,employee_number,department,org_id,role,is_active,can_view_reports")
    .eq("id", userId)
    .maybeSingle();
  if (!target || target.role !== "org_admin" || !target.is_active) return json({ ok: false, code: "ORG_ADMIN_NOT_FOUND" }, 404);
  const email = requestedEmail || target.email;

  const { data: duplicateEmployeeNumber } = await client.from("profiles")
    .select("id")
    .ilike("employee_number", employeeNumber)
    .neq("id", userId)
    .maybeSingle();
  if (duplicateEmployeeNumber) return json({ ok: false, code: "EMPLOYEE_NUMBER_EXISTS" }, 409);

  const { data: authTarget, error: authReadError } = await client.auth.admin.getUserById(userId);
  if (authReadError || !authTarget.user) return json({ ok: false, code: "AUTH_ACCOUNT_NOT_FOUND" }, 404);
  const currentAuthEmail = (authTarget.user.email || "").trim().toLowerCase();
  if (email !== currentAuthEmail) {
    const { data: authUsers, error: authListError } = await client.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (authListError) return json({ ok: false, code: "AUTH_ACCOUNT_LOOKUP_FAILED" }, 503);
    const duplicateAuthUser = authUsers.users.find((user) => user.id !== userId && user.email?.trim().toLowerCase() === email);
    if (duplicateAuthUser) return json({ ok: false, code: "EMAIL_ALREADY_EXISTS" }, 409);
    let { error: authEmailError } = await client.auth.admin.updateUserById(userId, { email, email_confirm: true });
    if (authEmailError) {
      const message = authEmailError.message.toLowerCase();
      const code = /already|registered|exists|duplicate/.test(message) ? "EMAIL_ALREADY_EXISTS" : /invalid.*email/.test(message) ? "INVALID_EMAIL" : "AUTH_EMAIL_UPDATE_FAILED";
      return json({ ok: false, code, authCode: authEmailError.code || null }, 409);
    }
  }
  if (password) {
    const { error: authPasswordError } = await client.auth.admin.updateUserById(userId, { password });
    if (authPasswordError) {
      return json({ ok: false, code: /password/i.test(authPasswordError.message) ? "INVALID_PASSWORD" : "AUTH_PASSWORD_UPDATE_FAILED", authCode: authPasswordError.code || null }, 409);
    }
  }

  const { data: profile, error: profileError } = await client.from("profiles").update({
    email, name, employee_number: employeeNumber, department,
  }).eq("id", userId).eq("role", "org_admin").select("*").maybeSingle();
  if (profileError || !profile) {
    if (email !== currentAuthEmail) await client.auth.admin.updateUserById(userId, { email: currentAuthEmail, email_confirm: true });
    return json({ ok: false, code: "PROFILE_UPDATE_FAILED" }, 409);
  }
  const { error: metadataError } = await client.auth.admin.updateUserById(userId, {
    user_metadata: { ...authTarget.user.user_metadata, name, employee_number: employeeNumber, department },
  });
  await client.from("attendance_audit_logs").insert({
    employee_id: userId,
    action_type: "org_admin_account_updated",
    changed_field: "org_admin_account",
    before_value: JSON.stringify({ name: target.name, employee_number: target.employee_number, department: target.department }),
    after_value: JSON.stringify({ name, employee_number: employeeNumber, department }),
    reason: "최고관리자가 기관관리자 계정 정보를 변경했습니다.",
    changed_by: actor?.id,
    changed_by_role: actor?.role,
    org_id: target.org_id,
  });
  return json({ ok: true, profile, metadataSynced: !metadataError });
}

export async function DELETE(request: Request) {
  const { client, actor, error: contextError } = await context(request);
  if (!client) return contextError as Response;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const userId = typeof body?.userId === "string" ? body.userId.trim() : "";
  if (!validUserId(userId)) return json({ ok: false, code: "INVALID_INPUT" }, 400);

  const { data: target } = await client.from("profiles")
    .select("id,email,name,employee_number,department,org_id,role,is_active")
    .eq("id", userId)
    .maybeSingle();
  if (!target || target.role !== "org_admin" || !target.is_active) return json({ ok: false, code: "ORG_ADMIN_NOT_FOUND" }, 404);

  const archivedEmail = `archived-org-admin-${userId}@attendance.invalid`;
  const archivedEmployeeNumber = `DEL-${userId.slice(0, 8).toUpperCase()}`;
  const { data: authTarget, error: authReadError } = await client.auth.admin.getUserById(userId);
  if (authReadError || !authTarget.user) return json({ ok: false, code: "AUTH_ACCOUNT_NOT_FOUND" }, 404);
  const { error: authUpdateError } = await client.auth.admin.updateUserById(userId, {
    email: archivedEmail,
    email_confirm: true,
    ban_duration: "876000h",
    user_metadata: { ...authTarget.user.user_metadata, archived: true, archived_at: new Date().toISOString() },
  });
  if (authUpdateError) return json({ ok: false, code: "AUTH_ACCOUNT_DELETE_FAILED" }, 500);

  const { error: profileError } = await client.from("profiles").update({
    email: archivedEmail,
    employee_number: archivedEmployeeNumber,
    department: "삭제된 기관관리자",
    is_active: false,
    can_view_reports: false,
  }).eq("id", userId).eq("role", "org_admin");
  if (profileError) {
    await client.auth.admin.updateUserById(userId, {
      email: target.email,
      email_confirm: true,
      ban_duration: "none",
      user_metadata: authTarget.user.user_metadata,
    });
    return json({ ok: false, code: "PROFILE_DELETE_FAILED" }, 500);
  }
  await client.from("attendance_audit_logs").insert({
    employee_id: userId,
    action_type: "org_admin_account_deleted",
    changed_field: "org_admin_account",
    before_value: JSON.stringify({ name: target.name, employee_number: target.employee_number, department: target.department }),
    after_value: "기관관리자 계정 사용 중지",
    reason: "최고관리자가 기관관리자 계정을 삭제 처리했습니다.",
    changed_by: actor?.id,
    changed_by_role: actor?.role,
    org_id: target.org_id,
  });
  return json({ ok: true, retainedRecords: true });
}
