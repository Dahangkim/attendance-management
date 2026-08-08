import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

export async function GET(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  const query = client.from("organizations").select("*").order("short_name");
  const { data, error } = actor.role === "super_admin" ? await query : await query.eq("id", actor.org_id);
  if (error) return json({ ok: false, code: "ORGANIZATION_LIST_FAILED" }, 500);
  let adminQuery = client.from("profiles")
    .select("id,email,name,employee_number,department,org_id,role,is_active,can_view_reports")
    .eq("role", "org_admin")
    .eq("is_active", true)
    .order("is_active", { ascending: false })
    .order("name");
  if (actor.role !== "super_admin") adminQuery = adminQuery.eq("org_id", actor.org_id);
  const { data: organizationAdmins, error: adminError } = await adminQuery;
  if (adminError) return json({ ok: false, code: "ORGANIZATION_ADMIN_LIST_FAILED" }, 500);
  let employeeQuery = client.from("profiles")
    .select("id,email,name,employee_number,department,org_id,role,is_active,can_view_reports")
    .eq("role", "employee")
    .order("is_active", { ascending: false })
    .order("name");
  if (actor.role !== "super_admin") employeeQuery = employeeQuery.eq("org_id", actor.org_id);
  const { data: organizationEmployees, error: employeeError } = await employeeQuery;
  if (employeeError) return json({ ok: false, code: "ORGANIZATION_EMPLOYEE_LIST_FAILED" }, 500);
  return json({ ok: true, organizations: data, organizationAdmins, organizationEmployees });
}

export async function POST(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const orgCode = typeof body?.orgCode === "string" ? body.orgCode.trim().toLowerCase() : "";
  const orgName = typeof body?.orgName === "string" ? body.orgName.trim() : "";
  const shortName = typeof body?.shortName === "string" ? body.shortName.trim() : "";
  const domain = typeof body?.domain === "string" ? body.domain.trim().toLowerCase().replace(/\.$/, "") : null;
  if (!/^[a-z0-9][a-z0-9-]{1,49}$/.test(orgCode) || orgName.length < 2 || orgName.length > 100 || shortName.length < 1 || shortName.length > 50) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const { data: organization, error } = await client.from("organizations").insert({
    org_code: orgCode, org_name: orgName, short_name: shortName,
    organization_type: "facility", domain: domain || null, is_active: true,
  }).select("*").single();
  if (error || !organization) return json({ ok: false, code: /unique|duplicate/i.test(error?.message || "") ? "ORGANIZATION_EXISTS" : "ORGANIZATION_CREATE_FAILED" }, 409);
  await client.from("organization_settings").insert({ id: true, org_id: organization.id, updated_by: actor.id });
  await client.from("organization_work_policies").insert({ org_id: organization.id, attendance_mode: "fixed", updated_by: actor.id });
  await client.from("attendance_audit_logs").insert({
    employee_id: actor.id, action_type: "organization_created", changed_field: "organization",
    before_value: "없음", after_value: JSON.stringify({ org_name: organization.org_name, short_name: organization.short_name, org_code: organization.org_code }),
    reason: "최고관리자가 기관을 직접 만들었습니다.", changed_by: actor.id, changed_by_role: actor.role, org_id: organization.id,
  });
  return json({ ok: true, organization }, 201);
}

export async function PATCH(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const brandingOnly = body?.scope === "branding";
  const statusOnly = body?.scope === "status";
  const orgId = typeof body?.orgId === "string" ? body.orgId.trim() : "";
  if (statusOnly) {
    if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
    if (!orgId || typeof body?.isActive !== "boolean") return json({ ok: false, code: "INVALID_INPUT" }, 400);
    const { data: before } = await client.from("organizations").select("is_active,short_name").eq("id", orgId).maybeSingle();
    const { data: organization, error } = await client.from("organizations").update({ is_active: body.isActive }).eq("id", orgId).select("*").maybeSingle();
    if (error || !organization) return json({ ok: false, code: "ORGANIZATION_STATUS_UPDATE_FAILED" }, error ? 500 : 404);
    const { error: auditError } = await client.from("attendance_audit_logs").insert({
      employee_id: actor.id, action_type: body.isActive ? "organization_reactivated" : "organization_deactivated", changed_field: "organization_status",
      before_value: before?.is_active ? "사용 중" : "사용 중지", after_value: body.isActive ? "사용 중" : "사용 중지",
      reason: `최고관리자가 ${before?.short_name || "기관"} 사용 상태를 직접 변경했습니다.`, changed_by: actor.id, changed_by_role: actor.role, org_id: orgId,
    });
    return auditError ? json({ ok: false, code: "AUDIT_LOG_SAVE_FAILED" }, 500) : json({ ok: true, organization });
  }
  if (actor.role !== "super_admin" && (!brandingOnly || !["admin", "org_admin"].includes(actor.role) || orgId !== actor.org_id)) {
    return json({ ok: false, code: "ORGANIZATION_UPDATE_FORBIDDEN" }, 403);
  }
  const orgName = typeof body?.orgName === "string" ? body.orgName.trim() : "";
  const shortName = typeof body?.shortName === "string" ? body.shortName.trim() : "";
  const domain = typeof body?.domain === "string" ? body.domain.trim().toLowerCase().replace(/\.$/, "") : "";
  const brandTitle = typeof body?.brandTitle === "string" ? body.brandTitle.trim() : "";
  const brandDescription = typeof body?.brandDescription === "string" ? body.brandDescription.trim() : "";
  const brandPrimaryColor = typeof body?.brandPrimaryColor === "string" ? body.brandPrimaryColor.trim() : "";
  const brandAccentColor = typeof body?.brandAccentColor === "string" ? body.brandAccentColor.trim() : "";
  const brandSubtitle = typeof body?.brandSubtitle === "string" ? body.brandSubtitle.trim() : "";
  const brandMark = typeof body?.brandMark === "string" ? body.brandMark.trim().slice(0, 2) : "";
  const brandLogoUrl = typeof body?.brandLogoUrl === "string" ? body.brandLogoUrl.trim() : "";
  const isActive = typeof body?.isActive === "boolean" ? body.isActive : undefined;
  const validAssetUrl = !brandLogoUrl || brandLogoUrl.startsWith("/") || /^https:\/\//i.test(brandLogoUrl);
  if (!orgId || (brandPrimaryColor && !/^#[0-9a-f]{6}$/i.test(brandPrimaryColor)) || (brandAccentColor && !/^#[0-9a-f]{6}$/i.test(brandAccentColor)) || !validAssetUrl) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  if (!brandingOnly && (actor.role !== "super_admin" || orgName.length < 2 || orgName.length > 100 || shortName.length < 1 || shortName.length > 50)) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }
  const updates: Record<string, unknown> = {};
  if (Object.hasOwn(body || {}, "brandTitle")) { updates.brand_title = brandTitle || null; updates.brand_short_title = brandTitle || null; }
  if (Object.hasOwn(body || {}, "brandDescription")) updates.brand_description = brandDescription || null;
  if (Object.hasOwn(body || {}, "brandSubtitle")) updates.brand_subtitle = brandSubtitle || null;
  if (Object.hasOwn(body || {}, "brandMark")) updates.brand_mark = brandMark || null;
  if (Object.hasOwn(body || {}, "brandLogoUrl")) updates.brand_logo_url = brandLogoUrl || null;
  if (Object.hasOwn(body || {}, "brandPrimaryColor")) updates.brand_primary_color = brandPrimaryColor || null;
  if (Object.hasOwn(body || {}, "brandAccentColor")) updates.brand_accent_color = brandAccentColor || null;
  if (!brandingOnly) {
    updates.org_name = orgName;
    updates.short_name = shortName;
    updates.domain = domain || null;
    if (isActive !== undefined) updates.is_active = isActive;
  }
  const { data: beforeOrganization } = await client.from("organizations").select("*").eq("id", orgId).maybeSingle();
  const { data: organization, error } = await client.from("organizations").update(updates).eq("id", orgId).select("*").maybeSingle();
  if (error || !organization) {
    const errorCode = error?.code === "42703" ? "BRANDING_SCHEMA_REQUIRED"
      : /unique|duplicate/i.test(error?.message || "") ? "ORGANIZATION_EXISTS"
        : "ORGANIZATION_UPDATE_FAILED";
    return json({ ok: false, code: errorCode }, errorCode === "ORGANIZATION_EXISTS" ? 409 : error ? 500 : 404);
  }
  await client.from("attendance_audit_logs").insert({
    employee_id: actor.id, action_type: brandingOnly ? "organization_branding_updated" : "organization_information_updated",
    changed_field: brandingOnly ? "organization_branding" : "organization_information",
    before_value: JSON.stringify(beforeOrganization || {}), after_value: JSON.stringify(organization),
    reason: actor.role === "super_admin" ? "최고관리자가 기관 정보를 직접 변경했습니다." : "기관관리자가 기관 화면 설정을 변경했습니다.",
    changed_by: actor.id, changed_by_role: actor.role, org_id: orgId,
  });
  return json({ ok: true, organization });
}

export async function DELETE(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const orgId = typeof body?.orgId === "string" ? body.orgId.trim() : "";
  if (!orgId) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const { data: organization, error } = await client.from("organizations").update({ is_active: false }).eq("id", orgId).select("*").maybeSingle();
  if (error || !organization) return json({ ok: false, code: "ORGANIZATION_DEACTIVATE_FAILED" }, error ? 500 : 404);
  await client.from("attendance_audit_logs").insert({ employee_id: actor.id, action_type: "organization_deactivated", changed_field: "organization_status", before_value: "사용 중", after_value: "사용 중지", reason: "최고관리자가 기관 사용을 직접 중지했습니다.", changed_by: actor.id, changed_by_role: actor.role, org_id: orgId });
  return json({ ok: true, organization, retainedRecords: true });
}
