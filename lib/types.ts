export type Role = "employee" | "team_lead" | "org_admin" | "admin" | "super_admin";

export interface Organization {
  id: string;
  org_code: string;
  org_name: string;
  short_name: string;
  organization_type: "corporation" | "facility";
  parent_org_id: string | null;
  expected_staff_count: number | null;
  domain: string | null;
  is_active: boolean;
  brand_title?: string | null;
  brand_short_title?: string | null;
  brand_description?: string | null;
  brand_subtitle?: string | null;
  brand_mark?: string | null;
  brand_logo_url?: string | null;
  brand_primary_color?: string | null;
  brand_accent_color?: string | null;
  brand_og_image_url?: string | null;
}
export type WorkType = "office" | "direct_in" | "direct_out" | "field" | "education" | "business_trip" | "remote" | "approved_other";
export type LocationStatus = "inside" | "outside" | "low_accuracy" | "permission_denied" | "unavailable" | "not_checked";
export type AttendanceStatus = "normal" | "late" | "absent" | "missing_in" | "missing_out" | "location_review" | "admin_review" | "field" | "business_trip" | "education" | "leave" | "annual_leave" | "half_day" | "quarter_day" | "hourly_leave" | "sick_leave" | "holiday_work" | "working";

export interface Profile {
  id: string;
  email: string;
  name: string;
  role: Role;
  employee_number: string;
  department: string;
  is_active: boolean;
  can_view_reports?: boolean;
  must_change_password?: boolean;
  org_id?: string;
  brand_title?: string | null;
  brand_description?: string | null;
  brand_subtitle?: string | null;
  brand_mark?: string | null;
  brand_logo_url?: string | null;
  brand_primary_color?: string | null;
  brand_accent_color?: string | null;
}

export interface AttendanceRecord {
  id: string;
  employee_id: string;
  employee_name?: string;
  work_date: string;
  work_type: WorkType;
  clock_in_at: string | null;
  clock_out_at: string | null;
  clock_in_accuracy: number | null;
  clock_in_distance: number | null;
  clock_in_location_status: LocationStatus;
  clock_in_ip_address?: string | null;
  clock_in_ip_matched?: boolean;
  clock_out_accuracy: number | null;
  clock_out_distance: number | null;
  clock_out_location_status: LocationStatus;
  clock_out_ip_address?: string | null;
  clock_out_ip_matched?: boolean;
  attendance_status: AttendanceStatus;
  note: string;
  raw_overtime_minutes?: number;
  recorded_overtime_minutes?: number;
  overtime_status?: "none" | "pending" | "approved" | "rejected";
  approved_overtime_minutes?: number;
  comp_time_eligible_minutes?: number;
  leave_type?: "none" | "annual_leave" | "half_day" | "quarter_day" | "hourly_leave" | "sick_leave";
  is_closed: boolean;
  changed?: boolean;
}

export interface CompTimeBalance {
  employee_id: string;
  total_granted_comp_time_minutes?: number;
  approved_overtime_minutes: number;
  used_comp_time_minutes: number;
  available_comp_time_minutes: number;
  expired_comp_time_minutes?: number;
  next_expiry_on?: string | null;
  expiring_soon_minutes?: number;
}

export interface AnnualLeaveBalance {
  entitlement_id: string;
  employee_id: string;
  valid_from: string;
  valid_to: string;
  base_minutes: number;
  granted_minutes: number;
  carryover_minutes: number;
  adjustment_minutes: number;
  used_minutes: number;
  scheduled_minutes: number;
  remaining_minutes: number;
  reason: string;
}

export interface CompTimeCredit {
  id: string;
  employee_id: string;
  employee_name?: string;
  source_type: "overtime" | "opening_balance" | "admin_adjustment";
  source_date: string;
  granted_minutes: number;
  used_minutes: number;
  remaining_minutes: number;
  expires_on: string;
  reason: string;
}

export interface MonthlyOvertimeAfterComp {
  employee_id: string;
  source_month: string;
  approved_overtime_minutes: number;
  comp_time_used_from_source_minutes: number;
  overtime_after_comp_minutes: number;
}

export interface CorrectionRequest {
  id: string;
  attendance_record_id: string | null;
  employee_id: string;
  employee_name?: string;
  target_date: string;
  end_date?: string | null;
  start_time?: string | null;
  end_time?: string | null;
  calculated_minutes?: number;
  approved_minutes?: number;
  request_subtype?: string;
  request_type: string;
  before_value: string;
  requested_value: string;
  reason: string;
  status: "pending" | "approved" | "rejected" | "more_info" | "cancelled";
  reviewer_comment: string;
  requested_at: string;
  reviewed_at: string | null;
  reviewer_name?: string | null;
}

export interface AuditLog {
  id: string;
  org_id?: string;
  organization_name?: string;
  attendance_record_id: string | null;
  employee_id: string;
  employee_name?: string;
  action_type: string;
  changed_field: string;
  before_value: string;
  after_value: string;
  reason: string;
  changed_by_name?: string;
  changed_by_role?: Role;
  created_at: string;
  target_work_date?: string | null;
}

export interface AdminLoginLog {
  id: string;
  org_id: string | null;
  organization_name?: string;
  profile_id: string;
  profile_name?: string;
  role: "org_admin" | "admin" | "super_admin";
  ip_address: string;
  device_info: string;
  created_at: string;
}

export interface AttendanceException {
  id: string;
  employee_id: string;
  employee_name?: string;
  start_date: string;
  end_date: string;
  exception_type: "business_trip" | "external_training" | "approved_other" | "annual_leave" | "comp_time" | "sick_leave" | "special_leave" | "other_leave";
  reason: string;
  approved_by: string;
  approved_by_name?: string;
  approved_at: string;
  cancelled_at: string | null;
}

export interface Workplace {
  id: string;
  workplace_name: string;
  latitude: number;
  longitude: number;
  allowed_radius_meters: number;
  low_accuracy_threshold_meters: number;
}

export interface OrganizationSettings {
  id: boolean;
  timezone: string;
  default_start_time: string;
  default_end_time: string;
  break_minutes: number;
  late_grace_minutes: number;
  early_leave_grace_minutes: number;
  office_ip_address: string;
  emergency_support_enabled: boolean;
}

export interface OrganizationWorkPolicy {
  org_id: string;
  attendance_mode: "fixed" | "flexible" | "shift";
  work_date_boundary_time: string;
  max_open_shift_hours: number;
  overtime_rounding_minutes: 1 | 5 | 10 | 15 | 30 | 60;
  holiday_work_counts_as_overtime: boolean;
  require_location: boolean;
  require_office_ip: boolean;
}

export interface WorkShiftTemplate {
  id: string;
  org_id: string;
  shift_code: string;
  shift_name: string;
  start_time: string;
  end_time: string;
  crosses_midnight: boolean;
  break_minutes: number;
  late_grace_minutes: number;
  early_leave_grace_minutes: number;
  is_active: boolean;
}

export interface EmployeeShiftAssignment {
  id: string;
  org_id: string;
  employee_id: string;
  work_date: string;
  shift_template_id: string;
  note: string;
}

export interface OrganizationChangeRequest {
  id: string;
  org_id: string;
  request_type: "workplace_location" | "office_ip" | "org_admin_account";
  action: "create" | "update" | "replace" | "deactivate";
  target_profile_id: string | null;
  proposed_values: Record<string, unknown>;
  reason: string;
  status: "pending" | "approved" | "rejected";
  requested_at: string;
  reviewed_at: string | null;
  review_note: string;
  requested_by?: string;
  reviewed_by?: string | null;
}

export interface Holiday {
  org_id?: string;
  holiday_date: string;
  holiday_name: string;
  is_paid_holiday: boolean;
}

export const WORK_TYPE_LABEL: Record<WorkType, string> = {
  office: "사무실 근무",
  direct_in: "직출",
  direct_out: "직퇴",
  field: "외근",
  education: "교육",
  business_trip: "출장",
  remote: "재택근무",
  approved_other: "기타 승인근무",
};

export const STATUS_LABEL: Record<AttendanceStatus, string> = {
  normal: "정상",
  late: "지각",
  absent: "기록 없음 확인 필요",
  missing_in: "출근 누락",
  missing_out: "퇴근 누락",
  location_review: "위치 확인 필요",
  admin_review: "관리자 확인 필요",
  field: "관리자 확인 필요",
  business_trip: "출장 근무",
  education: "관리자 확인 필요",
  leave: "휴가",
  annual_leave: "연차",
  half_day: "반차",
  quarter_day: "반반차",
  hourly_leave: "1시간차",
  sick_leave: "병가",
  holiday_work: "휴일 시간외근무",
  working: "근무 중",
};

export const LOCATION_LABEL: Record<LocationStatus, string> = {
  inside: "사업장 반경 내",
  outside: "사업장 반경 밖",
  low_accuracy: "위치 정확도 낮음",
  permission_denied: "위치 권한 거부",
  unavailable: "위치 확인 실패",
  not_checked: "위치 미확인",
};
