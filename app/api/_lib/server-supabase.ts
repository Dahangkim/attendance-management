import { createClient } from "@supabase/supabase-js";

export function createServerSupabaseClient(supabaseUrl: string, secretKey: string, accessToken?: string) {
  const secretSafeFetch: typeof fetch = (input, init) => {
    const headers = new Headers(init?.headers);
    if (secretKey.startsWith("sb_secret_") && headers.get("authorization") === `Bearer ${secretKey}`) {
      headers.delete("authorization");
    }
    return fetch(input, { ...init, headers });
  };

  return createClient(supabaseUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: secretSafeFetch,
      headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : undefined,
    },
  });
}
