import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);
  if (actor.role !== "super_admin") return json({ ok: false, code: "SUPER_ADMIN_REQUIRED" }, 403);
  const requestUrl = new URL(request.url);
  const orgId = requestUrl.searchParams.get("orgId") || "";
  const month = requestUrl.searchParams.get("month") || "";
  if (!UUID_PATTERN.test(orgId) || !/^20\d{2}-(0[1-9]|1[0-2])$/.test(month)) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const from = `${month}-01`;
  const untilDate = new Date(`${from}T00:00:00+09:00`);
  untilDate.setMonth(untilDate.getMonth() + 1);
  const until = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Seoul" }).format(untilDate);
  const [{ data: organization }, { data: profiles, error: profileError }] = await Promise.all([
    client.from("organizations").select("*").eq("id", orgId).maybeSingle(),
    client.from("profiles").select("*").eq("org_id", orgId).order("is_active", { ascending: false }).order("name"),
  ]);
  if (!organization) return json({ ok: false, code: "ORGANIZATION_NOT_FOUND" }, 404);
  if (profileError) return json({ ok: false, code: "ORGANIZATION_DATA_FAILED" }, 500);
  const [records, requests, exceptions, audits, independentAudits, closing] = await Promise.all([
    client.from("attendance_records").select("*").eq("org_id", orgId).gte("work_date", from).lt("work_date", until).is("deleted_at", null).order("work_date", { ascending: false }),
    client.from("correction_requests").select("*").eq("org_id", orgId).gte("target_date", from).lt("target_date", until).order("requested_at", { ascending: false }),
    client.from("attendance_exceptions").select("*").eq("org_id", orgId).lt("start_date", until).gte("end_date", from).is("cancelled_at", null).order("start_date", { ascending: false }),
    client.from("attendance_audit_logs").select("*").eq("org_id", orgId).gte("created_at", new Date(`${from}T00:00:00+09:00`).toISOString()).lt("created_at", new Date(`${until}T00:00:00+09:00`).toISOString()).order("created_at", { ascending: false }),
    client.from("attendance_audit_logs").select("*").eq("changed_by_role", "super_admin").not("action_type", "in", '(organization_change_approved,organization_change_rejected)').gte("created_at", new Date(`${from}T00:00:00+09:00`).toISOString()).lt("created_at", new Date(`${until}T00:00:00+09:00`).toISOString()).order("created_at", { ascending: false }),
    client.from("monthly_closings").select("*").eq("org_id", orgId).eq("year", Number(month.slice(0, 4))).eq("month", Number(month.slice(5, 7))).maybeSingle(),
  ]);
  if ([records, requests, exceptions, audits, independentAudits, closing].some((result) => result.error)) return json({ ok: false, code: "ORGANIZATION_DATA_FAILED" }, 500);
  const profileMap = new Map((profiles || []).map((profile) => [profile.id, profile]));
  const combinedAudits = [...(audits.data || []), ...(independentAudits.data || []).filter((item) => !(audits.data || []).some((existing) => existing.id === item.id))];
  const missingAuditProfileIds = [...new Set(combinedAudits.flatMap((item) => [item.employee_id, item.changed_by]).filter((id): id is string => Boolean(id) && !profileMap.has(id)))];
  if (missingAuditProfileIds.length) {
    const { data: auditProfiles } = await client.from("profiles").select("id,name,employee_number,department,role").in("id", missingAuditProfileIds);
    for (const profile of auditProfiles || []) profileMap.set(profile.id, profile);
  }
  const namedRecords = (records.data || []).map((record) => ({ ...record, employee_name: profileMap.get(record.employee_id)?.name || "알 수 없음", employee_number: profileMap.get(record.employee_id)?.employee_number || "", department: profileMap.get(record.employee_id)?.department || "" }));
  const namedRequests = (requests.data || []).map((item) => ({ ...item, employee_name: profileMap.get(item.employee_id)?.name || "알 수 없음", reviewer_name: item.reviewer_id ? profileMap.get(item.reviewer_id)?.name || null : null }));
  const namedExceptions = (exceptions.data || []).map((item) => ({ ...item, employee_name: profileMap.get(item.employee_id)?.name || "알 수 없음", approved_by_name: profileMap.get(item.approved_by)?.name || null }));
  const auditOrganizationIds = [...new Set(combinedAudits.map((item) => item.org_id).filter((id): id is string => Boolean(id)))];
  const auditOrganizationsResult = auditOrganizationIds.length
    ? await client.from("organizations").select("id,short_name").in("id", auditOrganizationIds)
    : { data: [] as { id: string; short_name: string }[] };
  const auditOrganizations = auditOrganizationsResult.data;
  const organizationNameMap = new Map((auditOrganizations || []).map((item) => [item.id, item.short_name]));
  const namedAudits = combinedAudits.map((item) => ({ ...item, organization_name: item.org_id ? organizationNameMap.get(item.org_id) || "기관 미확인" : "통합관리", employee_name: profileMap.get(item.employee_id)?.name || "알 수 없음", changed_by_name: item.changed_by ? profileMap.get(item.changed_by)?.name || null : null }));
  return json({ ok: true, organization, profiles, records: namedRecords, requests: namedRequests, exceptions: namedExceptions, audits: namedAudits, closing: closing.data || null });
}
