export function toSupabasePassword(password: string) {
  return password.length >= 4 && password.length < 6 ? `attendance:${password}` : password;
}
