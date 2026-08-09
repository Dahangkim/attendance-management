export const EMPLOYEE_PASSWORD_MIN_LENGTH = 6;
export const PRIVILEGED_PASSWORD_MIN_LENGTH = 8;

export function isPrivilegedPassword(password: string) {
  return password.length >= PRIVILEGED_PASSWORD_MIN_LENGTH
    && /[A-Za-z]/.test(password)
    && /[0-9]/.test(password)
    && /[^A-Za-z0-9]/.test(password);
}

export function toSupabasePassword(password: string) {
  return password;
}
