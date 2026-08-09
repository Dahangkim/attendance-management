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
  if (!supabaseUrl || !secretKey) return json({ ok: false, code: "RESET_NOT_CONFIGURED" }, 503);

  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);

  const body = await request.json().catch(() => null) as { userId?: unknown; password?: unknown } | null;
  const userId = typeof body?.userId === "string" ? body.userId.trim() : "";
  const password = typeof body?.password === "string" ? body.password : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId) || password.length < 6) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }

  const adminClient = createServerSupabaseClient(supabaseUrl, secretKey);
  const { data: authData, error: authError } = await adminClient.auth.getUser(token);
  if (authError || !authData.user) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);

  const [{ data: actor }, { data: target }] = await Promise.all([
    adminClient.from("profiles").select("id, role, org_id, is_active").eq("id", authData.user.id).maybeSingle(),
    adminClient.from("profiles").select("id, role, org_id, is_active").eq("id", userId).maybeSingle(),
  ]);
  if (!actor?.is_active || !["admin", "org_admin"].includes(actor.role)) return json({ ok: false, code: "ORG_ADMIN_REQUIRED" }, 403);
  if (!target?.is_active || target.role !== "employee") return json({ ok: false, code: "EMPLOYEE_NOT_FOUND" }, 404);
  if (!actor.org_id || target.org_id !== actor.org_id) return json({ ok: false, code: "ORG_MISMATCH" }, 403);

  const { error: updateError } = await adminClient.auth.admin.updateUserById(userId, { password: toSupabasePassword(password) });
  if (updateError) return json({ ok: false, code: "PASSWORD_UPDATE_FAILED" }, 500);

  const { error: auditError } = await adminClient.from("attendance_audit_logs").insert({
    employee_id: userId,
    action_type: "password_reset",
    changed_field: "password",
    before_value: "보안상 기록하지 않음",
    after_value: "임시 비밀번호 설정",
    reason: "기관 관리자 비밀번호 초기화",
    changed_by: authData.user.id,
    changed_by_role: actor.role,
  });

  return json({ ok: true, auditLogged: !auditError }, 200);
}
