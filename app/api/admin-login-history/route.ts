import { runtimeEnv } from "../_lib/runtime-env";
import { authenticatedAdmin } from "../_lib/admin-auth";
import { createServerSupabaseClient } from "../_lib/server-supabase";

export const dynamic = "force-dynamic";
const json = (body: Record<string, unknown>, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

const maskIpAddress = (value: string) => {
  if (value.includes(".")) {
    const parts = value.split(".");
    return parts.length === 4 ? `${parts[0]}.${parts[1]}.***.***` : value;
  }
  if (value.includes(":")) return `${value.split(":").slice(0, 3).join(":")}:****`;
  return value;
};

export async function GET(request: Request) {
  const url = runtimeEnv.NEXT_PUBLIC_SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = runtimeEnv.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return json({ ok: false, code: "NOT_CONFIGURED" }, 503);
  const client = createServerSupabaseClient(url, key);
  const { actor, code } = await authenticatedAdmin(request, client);
  if (!actor) return json({ ok: false, code }, code === "AUTH_REQUIRED" ? 401 : 403);

  const month = new URL(request.url).searchParams.get("month") || "";
  if (!/^20\d{2}-(0[1-9]|1[0-2])$/.test(month)) return json({ ok: false, code: "INVALID_INPUT" }, 400);
  const from = new Date(`${month}-01T00:00:00+09:00`);
  const until = new Date(from);
  until.setMonth(until.getMonth() + 1);

  let query = client.from("admin_login_logs").select("*")
    .gte("created_at", from.toISOString()).lt("created_at", until.toISOString())
    .order("created_at", { ascending: false }).limit(1000);
  if (actor.role !== "super_admin") {
    query = query.eq("profile_id", actor.id);
  }
  const { data, error } = await query;
  if (error) return json({ ok: false, code: "LOGIN_HISTORY_FAILED" }, 500);

  const profileIds = [...new Set((data || []).map((item) => item.profile_id))];
  const orgIds = [...new Set((data || []).map((item) => item.org_id).filter((id): id is string => Boolean(id)))];
  const [{ data: profiles }, { data: organizations }] = await Promise.all([
    profileIds.length ? client.from("profiles").select("id,name").in("id", profileIds) : Promise.resolve({ data: [] }),
    orgIds.length ? client.from("organizations").select("id,short_name").in("id", orgIds) : Promise.resolve({ data: [] }),
  ]);
  const profileNames = new Map((profiles || []).map((item) => [item.id, item.name]));
  const organizationNames = new Map((organizations || []).map((item) => [item.id, item.short_name]));
  const logs = (data || []).map((item) => ({
    ...item,
    ip_address: actor.role === "super_admin" ? item.ip_address : maskIpAddress(item.ip_address),
    profile_name: profileNames.get(item.profile_id) || "관리자",
    organization_name: item.org_id ? organizationNames.get(item.org_id) || "기관 미확인" : "최고관리자",
  }));
  return json({ ok: true, logs });
}
