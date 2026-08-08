import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
const requestTypes = new Set(["workplace_location", "office_ip", "org_admin_account"]);
const normalizeIpAddress = (value: string) => value.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/^::ffff:/, "").replace(/%[a-z0-9._-]+$/i, "").replace(/^(\d{1,3}(?:\.\d{1,3}){3}):\d+$/, "$1");

export async function GET(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  let query = client.from("organization_change_requests").select("*").order("requested_at", { ascending: false });
  if (actor.role !== "super_admin") query = query.eq("org_id", actor.org_id);
  const { data, error } = await query;
  return error ? json({ ok: false, code: "REQUEST_LIST_FAILED" }, 500) : json({ ok: true, requests: data });
}

export async function POST(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (!["admin", "org_admin"].includes(actor.role)) return json({ ok: false, code: "ORG_ADMIN_REQUIRED" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const requestType = typeof body?.requestType === "string" ? body.requestType : "";
  const action = typeof body?.action === "string" ? body.action : "update";
  const reason = typeof body?.reason === "string" ? body.reason.trim() : "";
  const proposedValues = body?.proposedValues && typeof body.proposedValues === "object" && !Array.isArray(body.proposedValues) ? body.proposedValues : null;
  const targetProfileId = typeof body?.targetProfileId === "string" ? body.targetProfileId : null;
  if (requestType === "office_ip" && proposedValues) {
    const proposedIp = normalizeIpAddress(typeof (proposedValues as Record<string, unknown>).office_ip_address === "string" ? String((proposedValues as Record<string, unknown>).office_ip_address) : "");
    const { data: settings } = await client.from("organization_settings").select("office_ip_address").eq("org_id", actor.org_id).maybeSingle();
    if (proposedIp && proposedIp === normalizeIpAddress(settings?.office_ip_address || "")) return json({ ok: false, code: "UNCHANGED_VALUE" }, 409);
  }
  if (!requestTypes.has(requestType) || !["create", "update", "replace", "deactivate"].includes(action) || reason.length < 5 || reason.length > 1000 || !proposedValues) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const { data, error } = await client.from("organization_change_requests").insert({
    org_id: actor.org_id, request_type: requestType, action, target_profile_id: targetProfileId,
    proposed_values: proposedValues, reason, status: "pending", requested_by: actor.id,
  }).select("*").single();
  return error ? json({ ok: false, code: "REQUEST_CREATE_FAILED" }, 500) : json({ ok: true, request: data }, 201);
}

export async function PATCH(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const requestId = typeof body?.requestId === "string" ? body.requestId.trim() : "";
  const reason = typeof body?.reason === "string" ? body.reason.trim() : "";
  if (!requestId || reason.length < 2) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const { data: change } = await client.from("organization_change_requests").select("*").eq("id", requestId).in("status", ["approved", "rejected"]).maybeSingle();
  if (!change) return json({ ok: false, code: "REQUEST_NOT_REOPENABLE" }, 404);
  const { error } = await client.from("organization_change_requests").update({ status: "pending", reviewed_by: null, review_note: "", reviewed_at: null }).eq("id", requestId);
  if (error) return json({ ok: false, code: "REQUEST_REOPEN_FAILED" }, 500);
  const { error: auditError } = await client.from("attendance_audit_logs").insert({
    employee_id: change.requested_by, action_type: "organization_change_reopened", changed_field: change.request_type,
    before_value: JSON.stringify({ status: change.status, proposed_values: change.proposed_values }),
    after_value: JSON.stringify({ status: "pending", proposed_values: change.proposed_values }), reason,
    changed_by: actor.id, changed_by_role: actor.role, org_id: change.org_id,
  });
  return auditError ? json({ ok: false, code: "AUDIT_LOG_SAVE_FAILED" }, 500) : json({ ok: true });
}
