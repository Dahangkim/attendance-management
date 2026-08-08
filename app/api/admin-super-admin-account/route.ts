import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

export async function PATCH(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const employeeNumber = typeof body?.employeeNumber === "string" ? body.employeeNumber.trim().toUpperCase() : "";
  if (!/^[A-Z0-9-]{2,30}$/.test(employeeNumber)) return json({ ok: false, code: "INVALID_EMPLOYEE_NUMBER" }, 400);

  const { data: duplicate } = await client.from("profiles").select("id").ilike("employee_number", employeeNumber).neq("id", actor.id).limit(1).maybeSingle();
  if (duplicate) return json({ ok: false, code: "EMPLOYEE_NUMBER_ALREADY_EXISTS" }, 409);
  const { data: before } = await client.from("profiles").select("employee_number").eq("id", actor.id).maybeSingle();
  const { data: profile, error } = await client.from("profiles").update({ employee_number: employeeNumber, updated_at: new Date().toISOString() }).eq("id", actor.id).eq("role", "super_admin").select("*").maybeSingle();
  if (error || !profile) return json({ ok: false, code: "SUPER_ADMIN_ACCOUNT_UPDATE_FAILED" }, 500);

  await client.from("attendance_audit_logs").insert({
    employee_id: actor.id,
    action_type: "super_admin_employee_number_updated",
    changed_field: "employee_number",
    before_value: String(before?.employee_number || ""),
    after_value: employeeNumber,
    reason: "최고관리자 본인 로그인 사번 변경",
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: null,
  });
  return json({ ok: true, profile });
}
