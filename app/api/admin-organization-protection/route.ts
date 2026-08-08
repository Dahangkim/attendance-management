import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

function textValue(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}
const normalizeIpAddress = (value: string) => value.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/^::ffff:/, "").replace(/%[a-z0-9._-]+$/i, "").replace(/^(\d{1,3}(?:\.\d{1,3}){3}):\d+$/, "$1");

export async function GET(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const orgId = new URL(request.url).searchParams.get("orgId")?.trim() || "";
  if (!orgId) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const [settingsResult, workplaceResult] = await Promise.all([
    client.from("organization_settings").select("*").eq("org_id", orgId).maybeSingle(),
    client.from("workplaces").select("*").eq("org_id", orgId).eq("is_active", true).maybeSingle(),
  ]);
  if (settingsResult.error || workplaceResult.error) return json({ ok: false, code: "PROTECTION_SETTINGS_LOAD_FAILED" }, 500);
  return json({ ok: true, organizationSettings: settingsResult.data, workplace: workplaceResult.data });
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
  const orgId = textValue(body?.orgId);
  const reason = textValue(body?.reason);
  const workplaceName = textValue(body?.workplaceName);
  const officeIpAddress = textValue(body?.officeIpAddress);
  const latitude = Number(body?.latitude);
  const longitude = Number(body?.longitude);
  const allowedRadiusMeters = Number(body?.allowedRadiusMeters);
  const lowAccuracyThresholdMeters = Number(body?.lowAccuracyThresholdMeters);
  if (!orgId || workplaceName.length < 2 || !Number.isFinite(latitude) || latitude < -90 || latitude > 90 || !Number.isFinite(longitude) || longitude < -180 || longitude > 180 || !Number.isInteger(allowedRadiusMeters) || allowedRadiusMeters < 50 || allowedRadiusMeters > 1000 || !Number.isInteger(lowAccuracyThresholdMeters) || lowAccuracyThresholdMeters < 10 || lowAccuracyThresholdMeters > 1000 || officeIpAddress.length > 128) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const { data: organization } = await client.from("organizations").select("id").eq("id", orgId).maybeSingle();
  if (!organization) return json({ ok: false, code: "ORGANIZATION_NOT_FOUND" }, 404);
  const [beforeSettingsResult, beforeWorkplaceResult] = await Promise.all([
    client.from("organization_settings").select("*").eq("org_id", orgId).maybeSingle(),
    client.from("workplaces").select("*").eq("org_id", orgId).eq("is_active", true).maybeSingle(),
  ]);
  if (beforeSettingsResult.error || beforeWorkplaceResult.error) return json({ ok: false, code: "PROTECTION_SETTINGS_LOAD_FAILED" }, 500);
  const beforeWorkplace = beforeWorkplaceResult.data;
  const unchanged = Boolean(beforeWorkplace && beforeSettingsResult.data)
    && workplaceName === String(beforeWorkplace.workplace_name || "").trim()
    && latitude === Number(beforeWorkplace.latitude) && longitude === Number(beforeWorkplace.longitude)
    && allowedRadiusMeters === Number(beforeWorkplace.allowed_radius_meters)
    && lowAccuracyThresholdMeters === Number(beforeWorkplace.low_accuracy_threshold_meters)
    && normalizeIpAddress(officeIpAddress) === normalizeIpAddress(beforeSettingsResult.data.office_ip_address || "");
  if (unchanged) return json({ ok: false, code: "UNCHANGED_VALUE" }, 409);
  if (reason.length < 5) return json({ ok: false, code: "REASON_REQUIRED" }, 400);

  const { data: organizationSettings, error: settingsError } = await client.from("organization_settings").upsert({
    id: true,
    org_id: orgId,
    office_ip_address: officeIpAddress,
    updated_by: actor.id,
    updated_at: new Date().toISOString(),
  }, { onConflict: "org_id" }).select("*").single();
  if (settingsError || !organizationSettings) return json({ ok: false, code: "ORGANIZATION_SETTINGS_UPDATE_FAILED" }, 500);

  let workplace;
  if (beforeWorkplaceResult.data) {
    const result = await client.from("workplaces").update({
      workplace_name: workplaceName,
      latitude,
      longitude,
      allowed_radius_meters: allowedRadiusMeters,
      low_accuracy_threshold_meters: lowAccuracyThresholdMeters,
      updated_at: new Date().toISOString(),
    }).eq("id", beforeWorkplaceResult.data.id).select("*").single();
    if (result.error || !result.data) return json({ ok: false, code: "WORKPLACE_UPDATE_FAILED" }, 500);
    workplace = result.data;
  } else {
    const result = await client.from("workplaces").insert({
      org_id: orgId,
      workplace_name: workplaceName,
      latitude,
      longitude,
      allowed_radius_meters: allowedRadiusMeters,
      low_accuracy_threshold_meters: lowAccuracyThresholdMeters,
      is_active: true,
    }).select("*").single();
    if (result.error || !result.data) return json({ ok: false, code: "WORKPLACE_CREATE_FAILED" }, 500);
    workplace = result.data;
  }

  const beforeValue = JSON.stringify({ office_ip_address: beforeSettingsResult.data?.office_ip_address || "", workplace: beforeWorkplaceResult.data || null });
  const afterValue = JSON.stringify({ office_ip_address: organizationSettings.office_ip_address || "", workplace });
  const { error: auditError } = await client.from("attendance_audit_logs").insert({
    employee_id: actor.id,
    action_type: "organization_protection_updated",
    changed_field: "workplace_and_office_ip",
    before_value: beforeValue,
    after_value: afterValue,
    reason,
    changed_by: actor.id,
    changed_by_role: actor.role,
    org_id: orgId,
  });
  if (auditError) return json({ ok: false, code: "AUDIT_LOG_SAVE_FAILED" }, 500);
  return json({ ok: true, organizationSettings, workplace });
}
