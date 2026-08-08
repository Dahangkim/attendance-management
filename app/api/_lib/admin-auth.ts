import type { SupabaseClient } from "@supabase/supabase-js";

export type AdminActor = {
  id: string;
  role: "admin" | "org_admin" | "super_admin";
  org_id: string;
  is_active: boolean;
};

export async function authenticatedAdmin(request: Request, client: SupabaseClient) {
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token) return { actor: null, code: "AUTH_REQUIRED" as const };
  const { data: authData, error: authError } = await client.auth.getUser(token);
  if (authError || !authData.user) return { actor: null, code: "AUTH_REQUIRED" as const };
  const { data } = await client.from("profiles")
    .select("id,role,org_id,is_active")
    .eq("id", authData.user.id)
    .maybeSingle();
  const actor = data as AdminActor | null;
  if (!actor?.is_active || !["admin", "org_admin", "super_admin"].includes(actor.role)) {
    return { actor: null, code: "ADMIN_REQUIRED" as const };
  }
  return { actor, code: null };
}
