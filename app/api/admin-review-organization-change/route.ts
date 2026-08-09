import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { isPrivilegedPassword, toSupabasePassword } from "../../../lib/auth-password";

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
  const requestId = typeof body?.requestId === "string" ? body.requestId : "";
  const decision = body?.decision === "approved" || body?.decision === "rejected" ? body.decision : "";
  const reviewNote = typeof body?.reviewNote === "string" ? body.reviewNote.trim() : "";
  const temporaryPassword = typeof body?.temporaryPassword === "string" ? body.temporaryPassword : "";
  if (!requestId || !decision || reviewNote.length < 2) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const { data: change } = await client.from("organization_change_requests").select("*").eq("id", requestId).eq("status", "pending").maybeSingle();
  if (!change) return json({ ok: false, code: "REQUEST_NOT_FOUND" }, 404);
  const values = change.proposed_values as Record<string, unknown>;
  if (decision === "approved") {
    if (change.request_type === "office_ip") {
      const officeIp = typeof values.office_ip_address === "string" ? values.office_ip_address.trim() : "";
      const { error } = await client.from("organization_settings").upsert({ id: true, org_id: change.org_id, office_ip_address: officeIp, updated_by: actor.id, updated_at: new Date().toISOString() }, { onConflict: "org_id" });
      if (error) return json({ ok: false, code: "CHANGE_APPLY_FAILED" }, 500);
    } else if (change.request_type === "workplace_location") {
      const latitude = Number(values.latitude); const longitude = Number(values.longitude);
      const radius = Number(values.allowed_radius_meters ?? 100); const threshold = Number(values.low_accuracy_threshold_meters ?? 100);
      const name = typeof values.workplace_name === "string" ? values.workplace_name.trim() : "";
      if (!name || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 || radius < 50 || radius > 1000 || threshold < 30 || threshold > 2000) return json({ ok: false, code: "INVALID_CHANGE_VALUES" }, 400);
      await client.from("workplaces").update({ is_active: false }).eq("org_id", change.org_id).eq("is_active", true);
      const { error } = await client.from("workplaces").insert({ org_id: change.org_id, workplace_name: name, latitude, longitude, allowed_radius_meters: radius, low_accuracy_threshold_meters: threshold, is_active: true });
      if (error) return json({ ok: false, code: "CHANGE_APPLY_FAILED" }, 500);
    } else if (change.request_type === "org_admin_account") {
      if (change.action === "deactivate") {
        const { error } = await client.from("profiles").update({ is_active: false, updated_at: new Date().toISOString() }).eq("id", change.target_profile_id).eq("org_id", change.org_id).eq("role", "org_admin");
        if (error) return json({ ok: false, code: "CHANGE_APPLY_FAILED" }, 500);
      } else if (change.action === "replace") {
        const name = typeof values.name === "string" ? values.name.trim() : "";
        const employeeNumber = typeof values.employee_number === "string" ? values.employee_number.trim().toUpperCase() : "";
        if (name.length < 2 || !/^[A-Z0-9-]{2,24}$/.test(employeeNumber) || !isPrivilegedPassword(temporaryPassword)) return json({ ok: false, code: "TEMPORARY_PASSWORD_REQUIRED" }, 400);
        const { data: duplicateNumber } = await client.from("profiles").select("id").ilike("employee_number", employeeNumber).neq("id", change.target_profile_id || "00000000-0000-0000-0000-000000000000").limit(1).maybeSingle();
        if (duplicateNumber) return json({ ok: false, code: "EMPLOYEE_NUMBER_EXISTS" }, 409);
        const { data: organization } = await client.from("organizations").select("org_code").eq("id", change.org_id).single();
        const email = `org-admin-${String(organization?.org_code || "organization").toLowerCase().replace(/[^a-z0-9-]/g, "-")}-${employeeNumber.toLowerCase()}@attendance.invalid`;
        const { data: created, error: authError } = await client.auth.admin.createUser({ email, password: toSupabasePassword(temporaryPassword), email_confirm: true, user_metadata: { name, employee_number: employeeNumber, department: "기관관리", org_code: organization?.org_code } });
        if (authError || !created.user) return json({ ok: false, code: "CHANGE_APPLY_FAILED" }, 500);
        const { error: profileError } = await client.from("profiles").upsert({ id: created.user.id, email, name, employee_number: employeeNumber, department: "기관관리", org_id: change.org_id, role: "org_admin", is_active: true, can_view_reports: true });
        if (profileError) { await client.auth.admin.deleteUser(created.user.id); return json({ ok: false, code: "CHANGE_APPLY_FAILED" }, 500); }
        if (change.target_profile_id) await client.from("profiles").update({ is_active: false, updated_at: new Date().toISOString() }).eq("id", change.target_profile_id).eq("org_id", change.org_id).eq("role", "org_admin");
      }
    }
  }
  const { error: reviewError } = await client.from("organization_change_requests").update({ status: decision, reviewed_by: actor.id, review_note: reviewNote, reviewed_at: new Date().toISOString() }).eq("id", requestId).eq("status", "pending");
  if (reviewError) return json({ ok: false, code: "REQUEST_REVIEW_FAILED" }, 500);
  const { error: auditError } = await client.from("attendance_audit_logs").insert({
    employee_id: change.requested_by,
    action_type: decision === "approved" ? "organization_change_approved" : "organization_change_rejected",
    changed_field: change.request_type,
    before_value: JSON.stringify({ status: "pending", proposed_values: change.proposed_values }),
    after_value: JSON.stringify({ status: decision, proposed_values: change.proposed_values }),
    reason: reviewNote,
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: change.org_id,
  });
  return auditError ? json({ ok: false, code: "AUDIT_LOG_SAVE_FAILED" }, 500) : json({ ok: true });
}
