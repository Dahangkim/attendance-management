import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
  ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

export const isSupabaseConfigured = Boolean(url && anonKey);

function installedAppStorage(): Storage | undefined {
  if (typeof window === "undefined") return undefined;
  const standaloneNavigator = navigator as Navigator & { standalone?: boolean };
  const installed = window.matchMedia("(display-mode: standalone)").matches || standaloneNavigator.standalone === true;
  return installed ? window.localStorage : window.sessionStorage;
}

export const supabase: SupabaseClient | null = isSupabaseConfigured ? createClient(url!, anonKey!, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storage: installedAppStorage(),
  },
}) : null;
