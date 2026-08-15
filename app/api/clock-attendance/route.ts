import { runtimeEnv } from "../_lib/runtime-env";
import { createServerSupabaseClient } from "../_lib/server-supabase";
import { resolveRequestIp } from "../_lib/client-ip";

export const dynamic = "force-dynamic";

const CLOCK_SERVER_VERSION = "2026-08-15-desktop-accuracy-v4";
const json = (body: Record<string, unknown>, status: number) => Response.json(body, {
  status,
  headers: { "Cache-Control": "no-store", "X-Clock-Server-Version": CLOCK_SERVER_VERSION },
});

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LOCATION_STATUSES = new Set(["inside", "outside", "low_accuracy", "permission_denied", "unavailable"]);

const numberOrNull = (value: unknown) => typeof value === "number" && Number.isFinite(value) ? value : null;

export async function POST(request: Request) {
  const supabaseUrl = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !secretKey) return json({ ok: false, code: "CLOCK_SERVER_NOT_CONFIGURED" }, 503);

  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);

  const body = await request.json().catch(() => null) as {
    action?: unknown;
    latitude?: unknown;
    longitude?: unknown;
    accuracy?: unknown;
    locationStatus?: unknown;
    note?: unknown;
    idempotencyKey?: unknown;
  } | null;
  const action = body?.action === "clock_in" || body?.action === "clock_out" ? body.action : "";
  const latitude = numberOrNull(body?.latitude);
  const longitude = numberOrNull(body?.longitude);
  const accuracy = numberOrNull(body?.accuracy);
  const locationStatus = typeof body?.locationStatus === "string" && LOCATION_STATUSES.has(body.locationStatus) ? body.locationStatus : "unavailable";
  const note = typeof body?.note === "string" ? body.note.trim() : "";
  const idempotencyKey = typeof body?.idempotencyKey === "string" ? body.idempotencyKey : "";
  if (!action || !UUID_PATTERN.test(idempotencyKey) || note.length > 500
    || latitude !== null && (latitude < -90 || latitude > 90)
    || longitude !== null && (longitude < -180 || longitude > 180)
    || accuracy !== null && (accuracy < 0 || accuracy > 40_000_000)) {
    return json({ ok: false, code: "INVALID_INPUT" }, 400);
  }

  const adminClient = createServerSupabaseClient(supabaseUrl, secretKey);
  const { data: authData, error: authError } = await adminClient.auth.getUser(token);
  if (authError || !authData.user) return json({ ok: false, code: "AUTH_REQUIRED" }, 401);
  const { data: profile } = await adminClient.from("profiles").select("id,is_active,org_id").eq("id", authData.user.id).maybeSingle();
  if (!profile?.is_active) return json({ ok: false, code: "INACTIVE_OR_UNKNOWN_USER" }, 403);
  const { data: organization } = await adminClient.from("organizations").select("id,is_active").eq("id", profile.org_id).maybeSingle();
  if (!organization?.is_active) return json({ ok: false, code: "ORGANIZATION_INACTIVE" }, 403);

  const trustedIp = await resolveRequestIp(request);
  const serverArgs = {
    p_employee_id: authData.user.id,
    p_action: action,
    p_latitude: latitude,
    p_longitude: longitude,
    p_accuracy: accuracy,
    p_location_status: locationStatus,
    p_ip_address: trustedIp || null,
    p_note: note,
    p_idempotency_key: idempotencyKey,
  };

  // 관리자가 퇴근시각만 비운 기록에는 예전 중복 방지 이벤트가 남아 있을 수 있습니다.
  // 실제 미퇴근 기록이 확인된 본인 건에 한해서 저장 전에 오래된 퇴근 이벤트를 정리합니다.
  if (action === "clock_out") {
    const { data: openRecord, error: openRecordError } = await adminClient.from("attendance_records")
      .select("id,work_date")
      .eq("employee_id", authData.user.id)
      .not("clock_in_at", "is", null)
      .is("clock_out_at", null)
      .is("deleted_at", null)
      .order("clock_in_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (openRecordError) return json({ ok: false, code: "CLOCK_OPEN_RECORD_CHECK_FAILED" }, 500);
    if (openRecord) {
      const { error: cleanupError } = await adminClient.from("attendance_events")
        .delete()
        .eq("employee_id", authData.user.id)
        .eq("work_date", openRecord.work_date)
        .eq("action_type", "clock_out");
      if (cleanupError) return json({ ok: false, code: "CLOCK_EVENT_CLEANUP_FAILED" }, 500);
    }
  }

  const callClockRpc = async () => {
    const response = await fetch(`${supabaseUrl}/rest/v1/rpc/clock_attendance_server_api`, {
      method: "POST",
      headers: {
        apikey: secretKey,
        ...(secretKey.startsWith("sb_secret_") ? {} : { Authorization: `Bearer ${secretKey}` }),
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({ p_payload: serverArgs }),
    });
    const payload = await response.json().catch(() => null) as string | {
      code?: string;
      message?: string;
      details?: string | null;
      hint?: string | null;
    } | null;
    return { response, payload };
  };
  const { response: rpcResponse, payload: rpcPayload } = await callClockRpc();
  const recordId = rpcResponse.ok && typeof rpcPayload === "string" ? rpcPayload : null;
  const error = rpcResponse.ok || typeof rpcPayload === "string" ? null : rpcPayload;
  if (error || !recordId) {
    const code = error?.code || String(error?.message || "CLOCK_FAILED").match(/[A-Z][A-Z0-9_]{3,}/)?.[0] || "CLOCK_FAILED";
    const status = code === "AUTH_REQUIRED" ? 401 : code === "INACTIVE_OR_UNKNOWN_USER" ? 403 : 400;
    return json({ ok: false, code, message: error?.message || "CLOCK_FAILED" }, status);
  }

  const { data: record } = await adminClient.from("attendance_records").select("id,work_date,clock_in_location_status,clock_out_location_status,clock_in_distance,clock_out_distance,clock_in_ip_matched,clock_out_ip_matched").eq("id", recordId).maybeSingle();
  const clockIn = action === "clock_in";
  return json({
    ok: true,
    recordId,
    workDate: record?.work_date || null,
    locationStatus: clockIn ? record?.clock_in_location_status : record?.clock_out_location_status,
    distance: clockIn ? record?.clock_in_distance : record?.clock_out_distance,
    ipMatched: Boolean(clockIn ? record?.clock_in_ip_matched : record?.clock_out_ip_matched),
  }, 200);
}
