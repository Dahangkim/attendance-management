import type { AttendanceRecord, AuditLog, CorrectionRequest, Profile, Workplace } from "./types";

export const demoProfiles: Profile[] = [
  { id: "emp-1", email: "employee1@example.org", name: "직원 1", role: "employee", employee_number: "260001", department: "상담팀", is_active: true },
  { id: "emp-2", email: "employee2@example.org", name: "직원 2", role: "employee", employee_number: "260002", department: "지원팀", is_active: true },
  { id: "admin-1", email: "admin@example.org", name: "최고관리자", role: "super_admin", employee_number: "000000", department: "운영팀", is_active: true },
];

const iso = (day: string, time: string) => `${day}T${time}:00+09:00`;
const d = (offset: number) => {
  const date = new Date();
  date.setDate(date.getDate() + offset);
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Seoul" }).format(date);
};

export const demoRecords: AttendanceRecord[] = [
  { id: "r1", employee_id: "emp-1", employee_name: "직원 1", work_date: d(-3), work_type: "office", clock_in_at: iso(d(-3), "08:56"), clock_out_at: iso(d(-3), "18:04"), clock_in_accuracy: 18, clock_in_distance: 22, clock_in_location_status: "inside", clock_out_accuracy: 21, clock_out_distance: 19, clock_out_location_status: "inside", attendance_status: "normal", note: "", is_closed: false },
  { id: "r2", employee_id: "emp-1", employee_name: "직원 1", work_date: d(-2), work_type: "office", clock_in_at: iso(d(-2), "09:02"), clock_out_at: iso(d(-2), "18:10"), clock_in_accuracy: 32, clock_in_distance: 2840, clock_in_location_status: "outside", clock_out_accuracy: 27, clock_out_distance: 43, clock_out_location_status: "inside", attendance_status: "admin_review", note: "외부 일정", is_closed: false },
  { id: "r3", employee_id: "emp-1", employee_name: "직원 1", work_date: d(-1), work_type: "office", clock_in_at: iso(d(-1), "08:59"), clock_out_at: null, clock_in_accuracy: 110, clock_in_distance: 5400, clock_in_location_status: "low_accuracy", clock_out_accuracy: null, clock_out_distance: null, clock_out_location_status: "not_checked", attendance_status: "missing_out", note: "위치 확인 필요", is_closed: false },
  { id: "r4", employee_id: "emp-2", employee_name: "직원 2", work_date: d(-1), work_type: "office", clock_in_at: iso(d(-1), "09:17"), clock_out_at: iso(d(-1), "18:02"), clock_in_accuracy: 16, clock_in_distance: 15, clock_in_location_status: "inside", clock_out_accuracy: 19, clock_out_distance: 21, clock_out_location_status: "inside", attendance_status: "late", note: "", is_closed: false },
];

export const demoRequests: CorrectionRequest[] = [
  { id: "c1", attendance_record_id: "r3", employee_id: "emp-1", employee_name: "직원 1", target_date: d(-1), request_type: "clock_out_at", before_value: "미기록", requested_value: "18:00", reason: "교육 종료 후 퇴근 기록을 누락했습니다.", status: "pending", reviewer_comment: "", requested_at: new Date().toISOString(), reviewed_at: null },
];

export const demoAuditLogs: AuditLog[] = [
  { id: "a1", attendance_record_id: "r2", employee_id: "emp-1", employee_name: "직원 1", action_type: "create", changed_field: "clock_in_at", before_value: "", after_value: "09:02", reason: "직출 기록", changed_by_name: "직원 1", changed_by_role: "employee", created_at: iso(d(-2), "09:02") },
];

export const demoWorkplace: Workplace = {
  id: "w1",
  workplace_name: "샘플 사업장",
  latitude: 37,
  longitude: 127,
  allowed_radius_meters: 100,
  low_accuracy_threshold_meters: 100,
};
