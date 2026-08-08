const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

export function normalizeHostname(value: string | null | undefined): string {
  const first = String(value || "").split(",", 1)[0].trim().toLowerCase();
  if (!first) return "";
  const unbracketed = first.startsWith("[") ? first.slice(1, first.indexOf("]")) : first;
  return unbracketed.replace(/:\d+$/, "").replace(/\.$/, "");
}

export function organizationLookupDomain(value: string | null | undefined): string | null {
  const hostname = normalizeHostname(value);
  if (!hostname || LOCAL_HOSTS.has(hostname)) return null;
  return hostname;
}
