"use client";

import { useEffect, useMemo, useState } from "react";
import {
  AlertCircle, ArrowRight, Building2, CalendarDays, Check,
  CheckCircle2, ChevronLeft, ChevronRight, Clock3, Download, FileClock, FileText,
  History, LoaderCircle, LocateFixed, LogIn, LogOut, MapPin, Menu, PencilLine,
  KeyRound, RefreshCw, Search, Settings, ShieldCheck, Trash2, Users, Wifi, X, XCircle,
} from "lucide-react";
import { demoAuditLogs, demoProfiles, demoRecords, demoRequests, demoWorkplace } from "../lib/demo-data";
import { requestCurrentLocation, type LocationResult } from "../lib/geo";
import { isSupabaseConfigured, supabase } from "../lib/supabase";
import { deploymentBrandingSource } from "../lib/deployment-branding";
import { DEFAULT_ACCENT_COLOR, DEFAULT_PRIMARY_COLOR, organizationBranding, type OrganizationBranding, type OrganizationBrandingSource } from "../lib/organization-branding";
import { applicationOwner } from "../lib/application-owner";
import { isPrivilegedPassword, toSupabasePassword } from "../lib/auth-password";
import {
  LOCATION_LABEL, STATUS_LABEL, type AttendanceException, type AttendanceRecord,
  type AnnualLeaveBalance, type AuditLog, type CompTimeBalance, type CompTimeCredit, type CorrectionRequest, type EmployeeShiftAssignment, type Holiday, type MonthlyOvertimeAfterComp, type Organization, type OrganizationChangeRequest, type OrganizationSettings, type OrganizationWorkPolicy, type Profile,
  type WorkShiftTemplate,
  type Role, type Workplace,
} from "../lib/types";

type EmployeeView = "today" | "records" | "corrections" | "team_reports" | "report_audit";
type AdminView = "organizations" | "org_reports" | "approvals" | "dashboard" | "monthly" | "leave_balances" | "exceptions" | "requests" | "audit" | "settings";
type InstallPromptEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: "accepted" | "dismissed" }> };

type TenantOrganization = OrganizationBrandingSource & { id: string; org_code: string; org_name: string; short_name: string; domain: string | null };
type Notice = { tone: "success" | "warning" | "error" | "info"; text: string } | null;
type MonthClosing = { year: number; month: number; status: "open" | "closed"; closed_at: string | null; reopened_at: string | null; reopen_reason: string };

const KST_DATE = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Seoul" });
async function signInWithCompatiblePassword(client: NonNullable<typeof supabase>, email: string, password: string) {
  const storedPassword = toSupabasePassword(password);
  const result = await client.auth.signInWithPassword({ email, password: storedPassword });
  return result.error && storedPassword !== password
    ? client.auth.signInWithPassword({ email, password })
    : result;
}
const formatDate = (value: string | Date) => new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", year: "numeric", month: "numeric", day: "numeric", weekday: "short" }).format(new Date(value));
const formatTime = (value: string | null) => value ? new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(value)) : "미기록";
const formatTimeInput = (value: string | null) => value ? new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(value)) : "";
const monthKey = (date = new Date()) => new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Seoul", year: "numeric", month: "2-digit" }).format(date);
const formatMonth = (value: string) => `${value.slice(0, 4)}년 ${Number(value.slice(5, 7))}월`;
const formatMinutes = (minutes = 0) => {
  if (minutes <= 0) return "없음";
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return [hours ? `${hours}시간` : "", remainder ? `${remainder}분` : ""].filter(Boolean).join(" ");
};
const REQUEST_TYPE_LABEL: Record<string, string> = {
  clock_in_at: "출근시각 수정",
  clock_out_at: "퇴근시각 수정",
  annual_leave: "연차 사용 신청",
  comp_time: "대체휴무 신청",
  sick_leave: "병가 신청",
  business_trip: "출장 신청",
  overtime: "시간외근무 신청",
  emergency_support: "긴급지원 근무",
  special_leave: "특별휴가 신청",
  other_leave: "기타 휴가 신청",
};
const EXCEPTION_TYPE_LABEL: Record<string, string> = {
  business_trip: "출장 근무",
  external_training: "외부교육",
  approved_other: "기타 승인 예외 근무",
  annual_leave: "종일 연차",
  comp_time: "종일 대체휴무",
  sick_leave: "종일 병가",
  special_leave: "종일 특별휴가",
  other_leave: "종일 기타 휴가",
};
const leaveUnitLabel = (minutes: number) => minutes === 480 ? "연차 1일" : minutes === 240 ? "반차 0.5일" : minutes === 120 ? "반반차 0.25일" : minutes === 60 ? "1시간차 0.125일" : formatMinutes(minutes);
const requestValueLabel = (request: CorrectionRequest) => {
  if (["clock_in_at", "clock_out_at"].includes(request.request_type)) return request.requested_value;
  if (request.request_type === "emergency_support" && !request.end_time) return "진행 중";
  const minutes = request.calculated_minutes || Number(request.requested_value) || 0;
  if (request.request_type === "overtime") return formatMinutes(minutes);
  if (request.request_type === "emergency_support") return formatMinutes(minutes);
  if (request.request_type === "annual_leave" && [60, 120, 240, 480].includes(minutes)) return leaveUnitLabel(minutes);
  const days = minutes / 480;
  const duration = `${formatMinutes(minutes)}${days ? `, ${Number(days.toFixed(3))}일` : ""}`;
  return ["special_leave", "other_leave"].includes(request.request_type) ? `${request.request_subtype || (request.request_type === "special_leave" ? "특별휴가" : "기타 휴가")}, ${duration}` : duration;
};
const requestPeriodLabel = (request: CorrectionRequest) => {
  const endDate = request.end_date || request.target_date;
  if (["clock_in_at", "clock_out_at"].includes(request.request_type)) return request.target_date;
  const dateRange = endDate === request.target_date ? request.target_date : `${request.target_date}부터 ${endDate}까지`;
  return request.request_type === "emergency_support" && !request.end_time
    ? `${request.target_date}, ${(request.start_time || "").slice(0, 5)} 시작, 진행 중`
    : `${dateRange}, ${(request.start_time || "").slice(0, 5)}부터 ${(request.end_time || "").slice(0, 5)}까지`;
};
const approvedEmergencyRequestsForRecord = (record: AttendanceRecord, requests: CorrectionRequest[]) => requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.employee_id === record.employee_id && (request.attendance_record_id === record.id || request.target_date === record.work_date));
const approvedEmergencyMinutesForRecord = (record: AttendanceRecord, requests: CorrectionRequest[]) => approvedEmergencyRequestsForRecord(record, requests).reduce((sum, request) => sum + (request.approved_minutes || request.calculated_minutes || 0), 0);
const approvedEmergencyMinutesForEmployeeDate = (requests: CorrectionRequest[], employeeId: string, workDate: string) => requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.employee_id === employeeId && request.target_date === workDate).reduce((sum, request) => sum + (request.approved_minutes || request.calculated_minutes || 0), 0);
const approvedEmergencyMinutesForEmployeeMonth = (requests: CorrectionRequest[], employeeId: string, month: string) => requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.employee_id === employeeId && request.target_date.startsWith(month)).reduce((sum, request) => sum + (request.approved_minutes || request.calculated_minutes || 0), 0);
const finishedEmergencyMinutesForRecord = (record: AttendanceRecord, requests: CorrectionRequest[]) => requests.filter((request) => request.request_type === "emergency_support" && Boolean(request.end_time) && request.employee_id === record.employee_id && (request.attendance_record_id === record.id || request.target_date === record.work_date)).reduce((sum, request) => sum + (request.calculated_minutes || 0), 0);
const regularApprovedOvertimeMinutes = (record: AttendanceRecord, _requests: CorrectionRequest[]) => record.approved_overtime_minutes || 0;
const totalApprovedOvertimeMinutes = (record: AttendanceRecord, requests: CorrectionRequest[]) => regularApprovedOvertimeMinutes(record, requests) + approvedEmergencyMinutesForRecord(record, requests);
const emergencyInterval = (request: CorrectionRequest) => request.end_date && request.start_time && request.end_time ? {
  start: new Date(`${request.target_date}T${request.start_time.slice(0, 8)}+09:00`).getTime(),
  end: new Date(`${request.end_date}T${request.end_time.slice(0, 8)}+09:00`).getTime(),
} : null;
const emergencyRequestsOverlap = (left: CorrectionRequest, right: CorrectionRequest) => {
  const leftInterval = emergencyInterval(left); const rightInterval = emergencyInterval(right);
  return Boolean(leftInterval && rightInterval && leftInterval.start < rightInterval.end && rightInterval.start < leftInterval.end);
};
const overlappingEmergencyRequests = (requests: CorrectionRequest[], employeeId: string, startDate: string, endDate: string, startTime: string, endTime: string, excludeId = "") => {
  const candidate = { id: excludeId, employee_id: employeeId, request_type: "emergency_support", status: "pending", target_date: startDate, end_date: endDate, start_time: startTime, end_time: endTime } as CorrectionRequest;
  return requests.filter((request) => request.id !== excludeId && request.employee_id === employeeId && request.request_type === "emergency_support" && !["rejected", "cancelled"].includes(request.status) && emergencyRequestsOverlap(candidate, request));
};
const emergencySupportRemark = (record: AttendanceRecord, requests: CorrectionRequest[]) => {
  const approved = approvedEmergencyRequestsForRecord(record, requests);
  const hasOverlap = approved.some((request, index) => approved.slice(index + 1).some((other) => emergencyRequestsOverlap(request, other)));
  return [
    ...approved.map((request) => `긴급지원 인정시간: ${formatMinutes(request.approved_minutes || request.calculated_minutes || 0)} (${request.start_time?.slice(0, 5) || ""}부터 ${request.end_time?.slice(0, 5) || ""}까지)`),
    hasOverlap ? "주의: 긴급지원 인정시간이 서로 겹칩니다. 중복 인정 여부를 확인하세요." : "",
  ].filter(Boolean).join(", ");
};
const emergencySupportRemarkForEmployeeDate = (requests: CorrectionRequest[], employeeId: string, workDate: string) => {
  const approved = requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.employee_id === employeeId && request.target_date === workDate);
  return approved.map((request) => `긴급지원 인정시간: ${formatMinutes(request.approved_minutes || request.calculated_minutes || 0)} (${request.start_time?.slice(0, 5) || ""}부터 ${request.end_time?.slice(0, 5) || ""}까지)`).join(", ");
};
const attendanceNoteWithoutEmergency = (note?: string | null) => (note || "").split("\n").filter((line) => !line.trim().startsWith("긴급지원")).join("\n").trim();
const effectiveClockOutAt = (record: AttendanceRecord, _requests: CorrectionRequest[]) => record.clock_out_at || null;
const readableTextColor = (hex: string) => {
  const normalized = /^#[0-9a-f]{6}$/i.test(hex) ? hex.slice(1) : "173f35";
  const channels = [0, 2, 4].map((index) => Number.parseInt(normalized.slice(index, index + 2), 16) / 255).map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  const luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
  return luminance > 0.45 ? "#17211d" : "#ffffff";
};
const timeToMinutes = (value: string) => { const [hour, minute] = value.split(":").map(Number); return hour * 60 + minute; };
const calculateRequestedMinutes = (requestType: string, startDate: string, endDate: string, startTime: string, endTime: string) => {
  if (!startDate || !endDate || !startTime || !endTime) return 0;
  if (requestType === "overtime") return startDate === endDate ? Math.max(0, timeToMinutes(endTime) - timeToMinutes(startTime)) : 0;
  if (requestType === "emergency_support") {
    const from = new Date(`${startDate}T${startTime}:00+09:00`);
    const until = new Date(`${endDate}T${endTime}:00+09:00`);
    return Math.max(0, Math.min(1_440, Math.floor((until.getTime() - from.getTime()) / 60_000)));
  }
  let total = 0;
  for (let cursor = new Date(`${startDate}T12:00:00+09:00`), last = new Date(`${endDate}T12:00:00+09:00`); cursor <= last; cursor = new Date(cursor.getTime() + 86_400_000)) {
    const day = cursor.getDay();
    if (day === 0 || day === 6) continue;
    const key = KST_DATE.format(cursor);
    const from = Math.max(540, key === startDate ? timeToMinutes(startTime) : 540);
    const until = Math.min(1080, key === endDate ? timeToMinutes(endTime) : 1080);
    const lunch = Math.max(0, Math.min(until, 780) - Math.max(from, 720));
    total += Math.max(0, Math.min(480, until - from - lunch));
  }
  return total;
};
const approvedRequestMinutesForDate = (request: CorrectionRequest, workDate: string, isHoliday = false) => {
  if (request.status !== "approved" || workDate < request.target_date || workDate > (request.end_date || request.target_date)) return 0;
  const date = new Date(`${workDate}T12:00:00+09:00`);
  if (isHoliday || [0, 6].includes(date.getDay())) return 0;
  if (!request.start_time || !request.end_time) return workDate === request.target_date ? request.calculated_minutes || Number(request.requested_value) || 0 : 0;
  const from = Math.max(540, workDate === request.target_date ? timeToMinutes(request.start_time) : 540);
  const until = Math.min(1080, workDate === (request.end_date || request.target_date) ? timeToMinutes(request.end_time) : 1080);
  const lunch = Math.max(0, Math.min(until, 780) - Math.max(from, 720));
  return Math.max(0, Math.min(480, until - from - lunch));
};
const attendanceLeaveLabel = (record: AttendanceRecord, requests: CorrectionRequest[]) => {
  const request = requests.find((item) => item.employee_id === record.employee_id
    && item.status === "approved"
    && ["annual_leave", "comp_time", "special_leave", "sick_leave", "other_leave"].includes(item.request_type)
    && item.target_date <= record.work_date
    && (item.end_date || item.target_date) >= record.work_date);
  if (request) {
    const minutes = approvedRequestMinutesForDate(request, record.work_date);
    if (request.request_type === "annual_leave") return leaveUnitLabel(minutes);
    if (request.request_type === "comp_time") return `대체휴무 ${formatMinutes(minutes)}`;
    if (request.request_type === "sick_leave") return `병가 ${Number((minutes / 480).toFixed(3))}일`;
    return `${request.request_subtype || (request.request_type === "special_leave" ? "특별휴가" : "기타 휴가")} ${formatMinutes(minutes)}`;
  }
  if (record.leave_type === "half_day") return "반차 4시간";
  if (record.leave_type === "quarter_day") return "반반차 2시간";
  return record.leave_type && record.leave_type !== "none" ? STATUS_LABEL[record.leave_type] || record.leave_type : "";
};
const calculateEditedOvertime = (clockIn: string, clockOut: string) => {
  if (!clockIn || !clockOut) return { raw: 0, recognized: 0 };
  const from = timeToMinutes(clockIn);
  const until = timeToMinutes(clockOut);
  if (until <= from) return { raw: 0, recognized: 0 };
  const lunch = Math.max(0, Math.min(until, 780) - Math.max(from, 720));
  const worked = Math.max(0, until - from - lunch);
  const raw = Math.max(0, worked - 480);
  const recognized = raw < 60 ? 0 : Math.min(240, 60 + Math.ceil((raw - 60) / 30) * 30);
  return { raw, recognized };
};
const leaveDays = (requests: CorrectionRequest[], employeeId: string, month: string, type: "annual_leave" | "special_leave" | "sick_leave" | "other_leave") => requests.filter((request) => request.employee_id === employeeId && request.status === "approved" && request.request_type === type && request.target_date.startsWith(month)).reduce((sum, request) => sum + (request.calculated_minutes || Number(request.requested_value) || 0) / 480, 0);
const compTimeMinutes = (requests: CorrectionRequest[], employeeId: string, month: string) => requests.filter((request) => request.employee_id === employeeId && request.status === "approved" && request.request_type === "comp_time" && request.target_date.startsWith(month)).reduce((sum, request) => sum + Number(request.requested_value || 0), 0);
const exceptionDaysInMonth = (exceptions: AttendanceException[], employeeId: string, month: string, type = "business_trip") => {
  const monthStart = `${month}-01`;
  const next = new Date(`${monthStart}T12:00:00+09:00`); next.setMonth(next.getMonth() + 1);
  const monthEnd = KST_DATE.format(next);
  return exceptions.filter((item) => item.employee_id === employeeId && item.exception_type === type && !item.cancelled_at && item.start_date < monthEnd && item.end_date >= monthStart).reduce((sum, item) => {
    const start = new Date(`${item.start_date < monthStart ? monthStart : item.start_date}T12:00:00+09:00`);
    const end = item.end_date >= monthEnd ? new Date(new Date(`${monthEnd}T12:00:00+09:00`).getTime() - 86_400_000) : new Date(`${item.end_date}T12:00:00+09:00`);
    return sum + Math.floor((end.getTime() - start.getTime()) / 86_400_000) + 1;
  }, 0);
};
const currentDateKey = () => KST_DATE.format(new Date());
const isAdminRole = (role: Role) => role === "admin" || role === "org_admin" || role === "super_admin";
const isLikelyDesktop = () => {
  if (typeof navigator === "undefined") return false;
  const navigatorWithHints = navigator as Navigator & { userAgentData?: { mobile?: boolean } };
  if (navigatorWithHints.userAgentData?.mobile) return false;
  if (/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent)) return false;
  if (/Macintosh/i.test(navigator.userAgent) && navigator.maxTouchPoints > 1) return false;
  const phoneSizedTouchScreen = navigator.maxTouchPoints > 0
    && window.matchMedia("(pointer: coarse)").matches
    && Math.min(window.screen.width, window.screen.height) <= 820;
  return !phoneSizedTouchScreen;
};
const DEFAULT_ORGANIZATION_SETTINGS: OrganizationSettings = { id: true, timezone: "Asia/Seoul", default_start_time: "09:00", default_end_time: "18:00", break_minutes: 60, late_grace_minutes: 0, early_leave_grace_minutes: 0, office_ip_address: "", emergency_support_enabled: true };
const DEFAULT_WORK_POLICY: OrganizationWorkPolicy = { org_id: "", attendance_mode: "fixed", work_date_boundary_time: "04:00", max_open_shift_hours: 24, overtime_rounding_minutes: 30, holiday_work_counts_as_overtime: true, require_location: true, require_office_ip: false };
const DEPLOYMENT_BRANDING = deploymentBrandingSource();
const SUPER_ADMIN_BRANDING: OrganizationBrandingSource = { ...DEPLOYMENT_BRANDING, org_code: "super-admin", short_name: "통합관리", brand_subtitle: "최고관리자 전용" };
const PUBLIC_LOGIN_BRANDING: OrganizationBrandingSource = DEPLOYMENT_BRANDING;
const superAdminBrandingSource = (profile?: Profile | null): OrganizationBrandingSource => ({
  ...SUPER_ADMIN_BRANDING,
  brand_title: profile?.brand_title || SUPER_ADMIN_BRANDING.brand_title,
  brand_description: profile?.brand_description || SUPER_ADMIN_BRANDING.brand_description,
  brand_subtitle: profile?.brand_subtitle || SUPER_ADMIN_BRANDING.brand_subtitle,
  brand_mark: profile?.brand_mark || SUPER_ADMIN_BRANDING.brand_mark,
  brand_logo_url: profile?.brand_logo_url || null,
  brand_primary_color: profile?.brand_primary_color || DEFAULT_PRIMARY_COLOR,
  brand_accent_color: profile?.brand_accent_color || DEFAULT_ACCENT_COLOR,
});
const ATTENDANCE_STATUS_FILTERS: AttendanceRecord["attendance_status"][] = ["normal", "working", "late", "missing_in", "missing_out", "location_review", "admin_review", "holiday_work", "annual_leave", "half_day", "quarter_day", "hourly_leave", "sick_leave"];
const normalizeOrganizationSettings = (value: OrganizationSettings): OrganizationSettings => ({ ...value, office_ip_address: value.office_ip_address || "", emergency_support_enabled: value.emergency_support_enabled !== false, default_start_time: value.default_start_time.slice(0, 5), default_end_time: value.default_end_time.slice(0, 5) });
const normalizeIpAddress = (value: string) => value.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/^::ffff:/, "").replace(/%[a-z0-9._-]+$/i, "").replace(/^(\d{1,3}(?:\.\d{1,3}){3}):\d+$/, "$1");
const fetchClientIp = async () => {
  try {
    const response = await fetch("/api/client-ip", { cache: "no-store" });
    const data = await response.json() as { ip?: string };
    return data.ip?.trim() || "";
  } catch { return ""; }
};

function clockErrorMessage(error: unknown, action?: "clock_in" | "clock_out") {
  const value = error && typeof error === "object" ? error as { code?: string; message?: string; details?: string; hint?: string } : {};
  const code = value.code || "";
  const detail = [value.message, value.details, value.hint].filter(Boolean).join(" ").trim();
  const raw = detail.toUpperCase();
  if (raw.includes("DUPLICATE_CLOCK_REQUEST")) return action === "clock_out" ? "오늘 퇴근 요청이 이미 처리됐습니다. 화면을 새로고침해 기록을 확인해 주세요." : "오늘 출근 요청이 이미 처리됐습니다. 화면을 새로고침해 기록을 확인해 주세요.";
  if (raw.includes("ALREADY_CLOCKED_IN")) return "오늘 출근은 이미 기록됐습니다. 화면을 새로고침해 기록을 확인해 주세요.";
  if (raw.includes("ALREADY_CLOCKED_OUT")) return "오늘 퇴근은 이미 기록됐습니다. 화면을 새로고침해 기록을 확인해 주세요.";
  if (raw.includes("CLOCK_IN_REQUIRED")) return "오늘 출근 기록을 찾지 못했습니다. 화면을 새로고침한 뒤 다시 확인해 주세요.";
  if (raw.includes("INACTIVE_OR_UNKNOWN_USER")) return "로그인 계정과 직원 정보가 연결되지 않았거나 사용 중지 상태입니다. 관리자에게 직원 계정의 활성 상태를 확인해 달라고 알려 주세요.";
  if (raw.includes("MONTH_CLOSED")) return "이미 마감된 달이라 기록할 수 없습니다. 관리자에게 월 마감 상태를 확인해 주세요.";
  if (raw.includes("LOCATION_REASON_REQUIRED")) return "위치 확인이 어려운 경우에는 사유를 입력해야 합니다.";
  if (raw.includes("INVALID_WORK_TYPE")) return "출퇴근 기본 설정이 서버에 반영되지 않았습니다. 관리자에게 데이터베이스 설정을 확인해 달라고 알려 주세요.";
  if (raw.includes("WORKPLACE_NOT_CONFIGURED")) return "사업장 기준점이 설정되지 않았습니다. 관리자가 사업장 설정을 먼저 저장해야 합니다.";
  if (raw.includes("CLOCK_SERVER_NOT_CONFIGURED")) return "출퇴근 보안 서버 설정이 완료되지 않았습니다. Cloudflare의 SUPABASE_SECRET_KEY 설정을 확인해 주세요.";
  if (raw.includes("CLOCK_OPEN_RECORD_CHECK_FAILED") || raw.includes("CLOCK_EVENT_CLEANUP_FAILED")) return "기존 퇴근 기록을 정리하지 못했습니다. 관리자에게 오늘 퇴근시각 삭제 후 재기록 오류라고 알려 주세요.";
  if (raw.includes("INVALID_INPUT")) return "출퇴근 요청값을 확인하지 못했습니다. 화면을 새로고침한 뒤 다시 시도해 주세요.";
  if (code === "23514") {
    const constraint = [value.message, value.details].filter(Boolean).join(" ").match(/constraint\s+[\"']?([^\"'\s]+)/i)?.[1];
    return `기관 데이터베이스의 출퇴근 허용값 규칙을 갱신해야 합니다${constraint ? ` (${constraint})` : ""}. 관리자에게 데이터베이스 보완 SQL 실행을 요청해 주세요.`;
  }
  if (code === "PGRST202" || code === "42883" || raw.includes("CLOCK_ATTENDANCE") && raw.includes("SCHEMA CACHE")) return `출퇴근 저장 기능을 Supabase API에서 찾지 못했습니다${detail ? ` (서버 응답: ${detail})` : ""}. 관리자에게 이 문구를 알려 주세요.`;
  if (code === "42501" || raw.includes("PERMISSION DENIED")) return `출퇴근 저장 권한이 거부되었습니다${detail ? ` (서버 응답: ${detail})` : ""}. 이 문구를 관리자에게 알려 주세요.`;
  if (typeof navigator !== "undefined" && !navigator.onLine) return "인터넷 연결이 끊겨 기록을 저장하지 못했습니다. 연결 후 다시 시도해 주세요.";
  if (code === "P0001") {
    const serverReason = String(value.message || "").trim();
    return `서버가 기록을 거부했습니다${serverReason ? ` (거부 사유: ${serverReason})` : ""}. 표시된 거부 사유를 관리자에게 알려 주세요.`;
  }
  return `기록 저장 중 서버 오류가 발생했습니다${code ? ` (오류코드 ${code})` : ""}. 같은 오류가 반복되면 이 문구를 관리자에게 알려 주세요.`;
}

function isClockAuthenticationError(error: unknown) {
  const value = error && typeof error === "object" ? error as { code?: string; message?: string; details?: string; hint?: string } : {};
  const raw = [value.code, value.message, value.details, value.hint].filter(Boolean).join(" ").toUpperCase();
  return raw.includes("INACTIVE_OR_UNKNOWN_USER") || raw.includes("AUTH_REQUIRED") || raw.includes("JWT EXPIRED") || raw.includes("INVALID JWT");
}

function attendancePlaceLabel(action: "clock_in" | "clock_out", status: AttendanceRecord["clock_in_location_status"], ipMatched = false) {
  if (ipMatched) return action === "clock_in" ? "일반 출근, 사무실 IP 일치" : "일반 퇴근, 사무실 IP 일치";
  if (status === "inside") return action === "clock_in" ? "일반 출근" : "일반 퇴근";
  if (status === "outside") return action === "clock_in" ? "직출" : "직퇴";
  if (status === "not_checked") return "미기록";
  return "위치 확인 필요";
}

const statusTone = (status: string) => {
  if (["normal", "inside", "approved", "annual_leave", "half_day", "quarter_day", "hourly_leave", "sick_leave"].includes(status)) return "positive";
  if (["working", "pending", "field", "education", "business_trip"].includes(status)) return "active";
  if (["late", "outside", "low_accuracy", "more_info", "location_review", "admin_review", "missing_in", "missing_out"].includes(status)) return "warning";
  if (["rejected", "cancelled", "absent", "permission_denied", "unavailable"].includes(status)) return "danger";
  return "neutral";
};
const AUDIT_FIELD_LABEL: Record<string, string> = {
  approved_overtime_minutes: "시간외근무 승인시간",
  attendance_status: "근태상태",
  attendance_record: "출퇴근기록",
  attendance_request: "근태 신청내용",
  request_status: "요청 처리상태",
  can_view_reports: "부관리자 조회 권한",
  employee_account: "직원 계정",
  is_active: "재직 상태",
  clock_in_at: "출근시각",
  clock_out_at: "퇴근시각",
  annual_leave: "연차",
  comp_time: "대체휴무",
  sick_leave: "병가",
  special_leave: "특별휴가",
  other_leave: "기타 휴가",
  annual_leave_balance: "연차 부여와 잔액",
  comp_time_balance: "대체휴무 적립과 잔액",
  comp_time_expiry: "대체휴무 사용기한",
  overtime: "시간외근무",
  business_trip: "출장",
  office_ip: "사무실 IP",
  workplace_location: "사업장 위치",
  org_admin_account: "기관관리자 계정",
  workplace_and_office_ip: "사업장 위치와 사무실 IP",
  super_admin_branding: "최고관리자 화면 설정",
};
const AUDIT_ACTION_LABEL: Record<string, string> = {
  overtime_review: "시간외근무 처리",
  overtime_review_reopened: "시간외근무 재검토",
  request_approved: "요청 승인",
  request_reopened: "요청 재검토",
  request_edited: "요청 수정",
  request_resubmitted: "신청 수정 재제출",
  admin_review_completed: "관리자 확인 완료",
  admin_leave_applied: "관리자 휴가 반영",
  comp_time_usage_unallocated: "대체휴무 미연결 사용 확인",
  correction_approved: "수정 승인",
  admin_create: "관리자 근무기록 추가",
  admin_update: "관리자 수정",
  admin_delete: "기록 삭제",
  admin_restore: "삭제 취소, 기록 복원",
  report_viewer_changed: "부관리자 권한 변경",
  employee_created: "직원 계정 생성",
  employee_deactivated: "퇴사 처리",
  employee_reactivated: "직원 재활성화",
  annual_leave_entitlement_saved: "연차 부여내역 저장",
  annual_leave_entitlement_deleted: "연차 부여내역 삭제",
  comp_time_credit_added: "대체휴무 시작 잔액 등록",
  comp_time_credit_updated: "대체휴무 적립내역 수정",
  comp_time_credit_deleted: "대체휴무 적립내역 삭제",
  comp_time_expiry_extended: "대체휴무 사용기한 연장",
  comp_time_expiry_reverted: "대체휴무 사용기한 되돌림",
  organization_protection_updated: "기관 위치와 IP 즉시 변경",
  organization_change_approved: "기관 설정 변경 승인",
  organization_change_rejected: "기관 설정 변경 반려",
  organization_change_reopened: "기관 설정 변경 재검토",
  org_admin_account_created: "기관관리자 계정 생성",
  org_admin_account_updated: "기관관리자 계정 수정",
  org_admin_account_deleted: "기관관리자 계정 삭제",
  super_admin_branding_updated: "최고관리자 내 화면 변경",
  super_admin_employee_number_updated: "최고관리자 로그인 사번 변경",
  organization_created: "기관 생성",
  organization_information_updated: "기관 정보 직접 변경",
  organization_branding_updated: "기관 화면 설정 변경",
  organization_deactivated: "기관 사용 중지",
  organization_reactivated: "기관 다시 사용",
  attendance_retention_purged: "보존기간 경과 기록 영구 삭제",
  external_training_record_create: "외부교육 근무기록 생성",
  emergency_support_started: "긴급지원 시작",
  emergency_support_finished: "긴급지원 종료",
  emergency_support_cancelled: "긴급지원 취소",
  emergency_support_employee_updated: "활동가 긴급지원 시간 수정",
  emergency_support_admin_updated: "관리자 긴급지원 시간 수정",
  emergency_support_review: "긴급지원 검토",
};
const auditFieldLabel = (field: string) => AUDIT_FIELD_LABEL[field] || REQUEST_TYPE_LABEL[field] || field.replaceAll("_", " ");
const readableAuditValue = (value: string) => {
  if (!value) return "없음";
  try {
    const parsed = JSON.parse(value) as { status?: string; minutes?: number; comp_time_eligible_minutes?: number };
    if (parsed.status === "approved") return `승인 ${formatMinutes(parsed.minutes || 0)}${parsed.comp_time_eligible_minutes ? `, 대체휴무 전환 가능 ${formatMinutes(parsed.comp_time_eligible_minutes)}` : ""}`;
    if (parsed.status === "rejected") return "반려";
  } catch { return value; }
  return value;
};
const auditDisplayValue = (log: AuditLog, value: string, position: "before" | "after") => {
  if (log.action_type === "organization_branding_updated") return position === "before" ? "이전 기관 화면 설정" : "변경된 기관 화면 설정";
  return readableAuditValue(value);
};
const auditDescription = (log: AuditLog) => {
  if (log.action_type === "overtime_review") return readableAuditValue(log.after_value) === "반려" ? "시간외근무를 반려했습니다." : `시간외근무를 ${readableAuditValue(log.after_value)} 처리했습니다.`;
  if (log.action_type === "request_approved") return `${REQUEST_TYPE_LABEL[log.changed_field] || auditFieldLabel(log.changed_field)}을 승인했습니다.`;
  if (log.action_type === "request_reopened") return "처리된 요청을 다시 검토 대기 상태로 변경했습니다.";
  if (log.action_type === "request_edited") return "근태 신청내용을 수정하고 다시 검토 대기로 변경했습니다.";
  if (log.action_type === "request_resubmitted") return "직원이 신청 내용을 수정해 다시 제출했습니다.";
  if (log.action_type === "admin_review_completed") return "관리자 확인 필요 기록을 확인 완료했습니다.";
  if (log.action_type === "admin_restore") return "삭제된 근태기록을 복원했습니다.";
  if (log.action_type === "report_viewer_changed") return `부관리자 조회 권한을 ${log.after_value === "true" ? "부여했습니다." : "해제했습니다."}`;
  if (log.action_type === "employee_created") return "새 직원 계정을 만들었습니다.";
  if (log.action_type === "employee_deactivated") return "직원을 퇴사 처리하고 로그인 목록에서 제외했습니다.";
  if (log.action_type === "employee_reactivated") return "직원 계정을 재활성화했습니다.";
  if (log.action_type === "organization_protection_updated") return "최고관리자가 사업장 위치와 사무실 IP를 즉시 변경했습니다.";
  if (log.action_type === "organization_change_approved") return `기관의 ${auditFieldLabel(log.changed_field)} 변경 요청을 승인했습니다.`;
  if (log.action_type === "organization_change_rejected") return `기관의 ${auditFieldLabel(log.changed_field)} 변경 요청을 반려했습니다.`;
  if (log.action_type === "comp_time_credit_updated") return "대체휴무 적립내역을 수정했습니다.";
  if (log.action_type === "comp_time_credit_deleted") return "대체휴무 적립내역을 삭제했습니다.";
  return `${auditFieldLabel(log.changed_field)}을 변경했습니다.`;
};

function Badge({ children, tone = "neutral" }: { children: React.ReactNode; tone?: string }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

function EmptyState({ title, text }: { title: string; text: string }) {
  return <div className="empty-state"><FileText size={28} /><strong>{title}</strong><p>{text}</p></div>;
}

function BrandIdentity({ branding, login = false }: { branding: OrganizationBranding; login?: boolean }) {
  return <div className={`brand${login ? " login-brand" : ""}`}>{branding.logoUrl ? <img className="brand-logo" src={branding.logoUrl} alt="" /> : <div className="brand-mark">{branding.mark}</div>}<div><strong>{branding.title}</strong><span>{branding.subtitle}</span></div></div>;
}

function SupportContact({ compact = false }: { compact?: boolean }) {
  const ownerName = applicationOwner.maintainerEmail
    ? <a href={`mailto:${applicationOwner.maintainerEmail}?subject=${encodeURIComponent("근태관리 프로그램 오류 제보")}`}>{applicationOwner.name}</a>
    : applicationOwner.name;
  return <div className={compact ? "support-contact compact" : "support-contact"}><strong>프로그램 기술지원 {ownerName}</strong><span>오류와 기능 개선 문의만 받습니다. 이름, 사번, 근태기록 등 개인정보를 보내지 마세요.</span></div>;
}

function InstitutionSupportNotice({ compact = false }: { compact?: boolean }) {
  return <div className={compact ? "support-contact compact" : "support-contact"}><strong>근태와 계정 문의</strong><span>근태기록, 신청, 로그인과 계정 문의는 소속 기관 관리자에게 문의하세요.</span></div>;
}

function AppLoadingScreen({ branding }: { branding: OrganizationBranding }) {
  return <main className="app-loading" aria-live="polite">{branding.logoUrl ? <img className="brand-logo loading-brand-logo" src={branding.logoUrl} alt="" /> : <div className="brand-mark">{branding.mark}</div>}<LoaderCircle className="spin" /><strong>{branding.title}를 불러오고 있습니다</strong><span>로그인과 기관 기록을 확인하는 중입니다.</span></main>;
}

export default function AttendanceApp() {
  const [profile, setProfile] = useState<Profile | null>(isSupabaseConfigured ? null : demoProfiles[0]);
  const [authReady, setAuthReady] = useState(!isSupabaseConfigured);
  const [dataReady, setDataReady] = useState(!isSupabaseConfigured);
  const [rolePreview, setRolePreview] = useState<Role>("employee");
  const [employeeView, setEmployeeView] = useState<EmployeeView>("today");
  const [adminView, setAdminView] = useState<AdminView>("organizations");
  const [records, setRecords] = useState<AttendanceRecord[]>(isSupabaseConfigured ? [] : demoRecords);
  const [profiles, setProfiles] = useState<Profile[]>(isSupabaseConfigured ? [] : demoProfiles);
  const [requests, setRequests] = useState<CorrectionRequest[]>(isSupabaseConfigured ? [] : demoRequests);
  const [auditLogs, setAuditLogs] = useState<AuditLog[]>(isSupabaseConfigured ? [] : demoAuditLogs);
  const [exceptions, setExceptions] = useState<AttendanceException[]>([]);
  const [compTimeBalances, setCompTimeBalances] = useState<CompTimeBalance[]>([]);
  const [annualLeaveBalances, setAnnualLeaveBalances] = useState<AnnualLeaveBalance[]>([]);
  const [compTimeCredits, setCompTimeCredits] = useState<CompTimeCredit[]>([]);
  const [monthlyOvertimeAfterComp, setMonthlyOvertimeAfterComp] = useState<MonthlyOvertimeAfterComp[]>([]);
  const [monthClosing, setMonthClosing] = useState<MonthClosing | null>(null);
  const [workplace, setWorkplace] = useState<Workplace>(demoWorkplace);
  const [selectedMonth, setSelectedMonth] = useState(monthKey());
  const [employeeFilter, setEmployeeFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  const [now, setNow] = useState(new Date());
  const [notice, setNotice] = useState<Notice>(null);
  const [retentionPreview, setRetentionPreview] = useState<{ deleteThroughYear: number; keepFromYear: number; attendanceRecords: number; correctionRequests: number; attendanceExceptions: number; auditLogs: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [consentOpen, setConsentOpen] = useState(false);
  const [pendingClockAction, setPendingClockAction] = useState<"clock_in" | "clock_out" | null>(null);
  const [hasLocationConsent, setHasLocationConsent] = useState(false);
  const [locationResult, setLocationResult] = useState<LocationResult | null>(null);
  const [correctionOpen, setCorrectionOpen] = useState(false);
  const [editingRecord, setEditingRecord] = useState<AttendanceRecord | null>(null);
  const [editingRequest, setEditingRequest] = useState<CorrectionRequest | null>(null);
  const [exceptionOpen, setExceptionOpen] = useState(false);
  const [attendanceCreateOpen, setAttendanceCreateOpen] = useState(false);
  const [emergencyWorkOpen, setEmergencyWorkOpen] = useState(false);
  const [employeeEmergencyWorkOpen, setEmployeeEmergencyWorkOpen] = useState(false);
  const [leaveApplyingRecord, setLeaveApplyingRecord] = useState<AttendanceRecord | null>(null);
  const [settingsDraft, setSettingsDraft] = useState(workplace);
  const [organizationSettingsDraft, setOrganizationSettingsDraft] = useState(DEFAULT_ORGANIZATION_SETTINGS);
  const [workPolicyDraft, setWorkPolicyDraft] = useState<OrganizationWorkPolicy>(DEFAULT_WORK_POLICY);
  const [shiftTemplates, setShiftTemplates] = useState<WorkShiftTemplate[]>([]);
  const [shiftAssignments, setShiftAssignments] = useState<EmployeeShiftAssignment[]>([]);
  const [organizationChangeRequests, setOrganizationChangeRequests] = useState<OrganizationChangeRequest[]>([]);
  const [loginIdentifier, setLoginIdentifier] = useState("");
  const [tenantOrganization, setTenantOrganization] = useState<TenantOrganization | null>(isSupabaseConfigured ? null : { id: "demo", org_code: "sample", org_name: "샘플 기관", short_name: "기관", domain: null });
  const [superAdminBranding, setSuperAdminBranding] = useState<OrganizationBrandingSource>(SUPER_ADMIN_BRANDING);
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [organizationAdmins, setOrganizationAdmins] = useState<Profile[]>([]);
  const [organizationEmployees, setOrganizationEmployees] = useState<Profile[]>([]);
  const [selectedOrgId, setSelectedOrgId] = useState("");
  const [selectedOrgWorkplace, setSelectedOrgWorkplace] = useState<Workplace | null>(null);
  const [selectedOrgSettings, setSelectedOrgSettings] = useState<OrganizationSettings | null>(null);
  const [loginPassword, setLoginPassword] = useState("");
  const [loginError, setLoginError] = useState("");
  const [passwordOpen, setPasswordOpen] = useState(false);
  const [passwordRecovery, setPasswordRecovery] = useState(false);
  const [resetPasswordTarget, setResetPasswordTarget] = useState<Profile | null>(null);
  const [employeeCreateOpen, setEmployeeCreateOpen] = useState(false);
  const [editingEmployee, setEditingEmployee] = useState<Profile | null>(null);
  const [installPrompt, setInstallPrompt] = useState<InstallPromptEvent | null>(null);
  const [iosInstallAvailable, setIosInstallAvailable] = useState(false);
  const [installGuideOpen, setInstallGuideOpen] = useState(false);
  const [holidayYear, setHolidayYear] = useState(Number(currentDateKey().slice(0, 4)) + 1);
  const [holidays, setHolidays] = useState<Holiday[]>([]);

  const effectiveRole: Role = isSupabaseConfigured ? (profile?.role || "employee") : rolePreview;
  const currentProfile = isSupabaseConfigured ? profile : (isAdminRole(effectiveRole) ? demoProfiles[2] : demoProfiles[0]);
  const tenantBranding = useMemo(() => organizationBranding(!profile && isSupabaseConfigured ? PUBLIC_LOGIN_BRANDING : effectiveRole === "super_admin" ? superAdminBranding : tenantOrganization), [effectiveRole, profile, superAdminBranding, tenantOrganization]);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 1_000);
    if ("serviceWorker" in navigator && process.env.NODE_ENV === "production") navigator.serviceWorker.register("/sw.js").catch(() => undefined);
    const captureInstallPrompt = (event: Event) => { event.preventDefault(); setInstallPrompt(event as InstallPromptEvent); };
    const navigatorWithStandalone = navigator as Navigator & { standalone?: boolean };
    const iosDevice = /iPhone|iPad|iPod/i.test(navigator.userAgent) || (/Macintosh/i.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
    const installed = window.matchMedia("(display-mode: standalone)").matches || navigatorWithStandalone.standalone === true;
    const iosInstallTimer = window.setTimeout(() => setIosInstallAvailable(iosDevice && !installed), 0);
    window.addEventListener("beforeinstallprompt", captureInstallPrompt);
    return () => { window.clearInterval(timer); window.clearTimeout(iosInstallTimer); window.removeEventListener("beforeinstallprompt", captureInstallPrompt); };
  }, []);

  useEffect(() => {
    const primaryContrast = readableTextColor(tenantBranding.primaryColor);
    const lightPrimary = primaryContrast === "#17211d";
    document.title = tenantBranding.title;
    document.documentElement.dataset.orgCode = tenantBranding.orgCode;
    document.documentElement.style.setProperty("--green", tenantBranding.primaryColor);
    document.documentElement.style.setProperty("--brand", tenantBranding.primaryColor);
    document.documentElement.style.setProperty("--lime", tenantBranding.accentColor);
    document.documentElement.style.setProperty("--green-contrast", primaryContrast);
    document.documentElement.style.setProperty("--lime-contrast", readableTextColor(tenantBranding.accentColor));
    document.documentElement.style.setProperty("--green-2", lightPrimary ? "#4b5752" : `color-mix(in srgb, ${tenantBranding.primaryColor} 82%, white)`);
    document.documentElement.style.setProperty("--green-deep", lightPrimary ? "#17211d" : `color-mix(in srgb, ${tenantBranding.primaryColor} 82%, black)`);
    document.documentElement.style.setProperty("--green-soft", lightPrimary ? "#eef0ed" : `color-mix(in srgb, ${tenantBranding.primaryColor} 8%, white)`);
    document.documentElement.style.setProperty("--mint", lightPrimary ? "#e7ebe8" : `color-mix(in srgb, ${tenantBranding.primaryColor} 14%, white)`);
    document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')?.setAttribute("content", tenantBranding.primaryColor);
  }, [tenantBranding]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 7_000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  useEffect(() => {
    const authClient = supabase;
    if (!authClient) return;
    let active = true;
    let checkingSession = false;
    const moveToLogin = (message = "") => {
      setProfile(null);
      setTenantOrganization(null);
      setSuperAdminBranding(SUPER_ADMIN_BRANDING);
      setEmployeeView("today");
      setAdminView("organizations");
      setMenuOpen(false);
      setLoginPassword("");
      setDataReady(false);
      setAuthReady(true);
      if (message) setLoginError(message);
    };
    const restoreSession = async (showExpiredMessage = false) => {
      if (checkingSession) return;
      checkingSession = true;
      const { data } = await authClient.auth.getSession();
      checkingSession = false;
      if (!active) return;
      if (data.session?.user) await loadProfile(data.session.user.id);
      else moveToLogin(showExpiredMessage ? "로그인이 만료되었습니다. 다시 로그인해 주세요." : "");
      if (active) setAuthReady(true);
    };
    void restoreSession();
    const { data: listener } = authClient.auth.onAuthStateChange((event, session) => {
      if (!active) return;
      if (event === "PASSWORD_RECOVERY") {
        setPasswordRecovery(true);
        setPasswordOpen(true);
      }
      if (session?.user) void loadProfile(session.user.id).finally(() => setAuthReady(true));
      else moveToLogin(event === "SIGNED_OUT" ? "로그아웃되었습니다. 다시 로그인해 주세요." : "");
    });
    const verifyWhenVisible = () => {
      if (document.visibilityState === "visible") void restoreSession(true);
    };
    window.addEventListener("focus", verifyWhenVisible);
    document.addEventListener("visibilitychange", verifyWhenVisible);
    return () => {
      active = false;
      listener.subscription.unsubscribe();
      window.removeEventListener("focus", verifyWhenVisible);
      document.removeEventListener("visibilitychange", verifyWhenVisible);
    };
  }, []);

  useEffect(() => {
    if (profile && supabase) {
      void loadRemoteData(profile).finally(() => setDataReady(true));
    }
    // 이 함수는 현재 프로필과 선택 월이 바뀔 때만 다시 호출해야 합니다.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profile, selectedMonth, selectedOrgId]);

  useEffect(() => {
    if (profile?.role === "super_admin" && supabase) void loadOrganizations();
    // 최고관리자 로그인 직후 한 번만 기관목록을 불러옵니다.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profile?.id, profile?.role]);

  useEffect(() => {
    if (profile?.role === "super_admin" && selectedOrgId && supabase) void loadSelectedOrganizationProtection();
  }, [profile?.id, profile?.role, selectedOrgId]);

  useEffect(() => {
    if (profile && supabase && ["super_admin", "admin", "org_admin"].includes(profile.role)) void loadOrganizationChangeRequests();
  }, [profile?.id, profile?.role]);

  useEffect(() => {
    if (profile && supabase && (isAdminRole(profile.role) || profile.can_view_reports)) void loadHolidays(holidayYear);
  }, [profile, holidayYear]);

  async function loadProfile(userId: string) {
    if (!supabase) return;
    const { data, error } = await supabase.from("profiles").select("*").eq("id", userId).single();
    if (error) {
      setAuthReady(true);
      setLoginError("로그인은 유지 중이지만 직원 정보를 불러오지 못했습니다. 인터넷 연결을 확인한 뒤 화면을 다시 열어 주세요.");
      return;
    }
    if (!data?.is_active) {
      await supabase.auth.signOut({ scope: "local" });
      setLoginError(data && !data.is_active ? "비활성 계정입니다. 관리자에게 문의해 주세요." : "직원 정보를 확인하지 못했습니다.");
      return;
    }
    if (data.must_change_password) {
      setPasswordRecovery(true);
      setPasswordOpen(true);
    }
    if (data.role !== "super_admin") {
      const { data: organization } = await supabase.from("organizations").select("id,org_code,org_name,short_name,domain,is_active,brand_title,brand_short_title,brand_description,brand_subtitle,brand_mark,brand_logo_url,brand_primary_color,brand_accent_color,brand_og_image_url").eq("id", data.org_id).maybeSingle();
      if (!organization?.is_active) {
        await supabase.auth.signOut({ scope: "local" });
        setLoginError("사용 중지된 기관입니다. 최고관리자에게 문의해 주세요.");
        return;
      }
      setTenantOrganization(organization as TenantOrganization);
    } else {
      setSuperAdminBranding(superAdminBrandingSource(data as Profile));
    }
    setLoginError("");
    if (data.role !== "super_admin") setAdminView((current) => current === "organizations" || current === "org_reports" ? "dashboard" : current);
    setProfile(data as Profile);
  }

  async function loadOrganizations(preferredOrgId?: string) {
    if (!supabase) return;
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      cache: "no-store",
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { organizations?: Organization[]; organizationAdmins?: Profile[]; organizationEmployees?: Profile[] } : {};
    if (!response?.ok || !Array.isArray(result.organizations)) {
      setNotice({ tone: "error", text: "기관 목록을 불러오지 못했습니다." });
      return;
    }
    setOrganizations(result.organizations);
    setOrganizationAdmins(Array.isArray(result.organizationAdmins) ? result.organizationAdmins : []);
    setOrganizationEmployees(Array.isArray(result.organizationEmployees) ? result.organizationEmployees : []);
    const nextId = preferredOrgId && result.organizations.some((item) => item.id === preferredOrgId)
      ? preferredOrgId
      : selectedOrgId && result.organizations.some((item) => item.id === selectedOrgId)
        ? selectedOrgId
        : result.organizations[0]?.id || "";
    setSelectedOrgId(nextId);
  }

  async function loadSelectedOrganizationProtection() {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch(`/api/admin-organization-protection?orgId=${encodeURIComponent(selectedOrgId)}`, {
      headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      cache: "no-store",
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { workplace?: Workplace | null; organizationSettings?: OrganizationSettings | null } : {};
    if (!response?.ok) {
      setSelectedOrgWorkplace(null);
      setSelectedOrgSettings(null);
      return;
    }
    setSelectedOrgWorkplace(result.workplace || null);
    setSelectedOrgSettings(result.organizationSettings ? normalizeOrganizationSettings(result.organizationSettings) : null);
  }

  async function updateSelectedOrganizationProtection(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const values = new FormData(form);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organization-protection", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        orgId: selectedOrgId,
        workplaceName: String(values.get("workplace_name") || ""),
        latitude: Number(values.get("latitude")),
        longitude: Number(values.get("longitude")),
        allowedRadiusMeters: Number(values.get("allowed_radius_meters")),
        lowAccuracyThresholdMeters: Number(values.get("low_accuracy_threshold_meters")),
        officeIpAddress: String(values.get("office_ip_address") || ""),
        reason: String(values.get("reason") || ""),
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { workplace?: Workplace; organizationSettings?: OrganizationSettings; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.workplace || !result.organizationSettings) {
      setNotice({ tone: result.code === "UNCHANGED_VALUE" ? "info" : "error", text: result.code === "UNCHANGED_VALUE" ? "현재 위치와 IP 설정과 같아 변경할 내용이 없습니다." : `기관 위치와 IP를 저장하지 못했습니다${result.code ? ` (${result.code})` : ""}.` });
      return;
    }
    setSelectedOrgWorkplace(result.workplace);
    setSelectedOrgSettings(normalizeOrganizationSettings(result.organizationSettings));
    if (currentProfile) await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "선택한 기관의 위치와 IP를 즉시 변경했고 변경이력에 남겼습니다." });
  }

  async function loadOrganizationChangeRequests() {
    if (!supabase) return;
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/organization-change-requests", { headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` }, cache: "no-store" }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { requests?: OrganizationChangeRequest[] } : {};
    if (response?.ok && Array.isArray(result.requests)) setOrganizationChangeRequests(result.requests);
  }

  async function requestOrganizationChange(form: HTMLFormElement, requestType: OrganizationChangeRequest["request_type"]) {
    if (!supabase || !["admin", "org_admin"].includes(effectiveRole)) return;
    const values = new FormData(form);
    const reason = String(values.get("reason") || "").trim();
    const proposedValues: Record<string, unknown> = requestType === "office_ip"
      ? { office_ip_address: String(values.get("office_ip_address") || "").trim() }
      : requestType === "workplace_location"
        ? { workplace_name: String(values.get("workplace_name") || "").trim(), latitude: Number(values.get("latitude")), longitude: Number(values.get("longitude")), allowed_radius_meters: Number(values.get("allowed_radius_meters") || 100), low_accuracy_threshold_meters: Number(values.get("low_accuracy_threshold_meters") || 100) }
        : { name: String(values.get("name") || "").trim(), employee_number: String(values.get("employee_number") || "").trim() };
    if (requestType === "office_ip" && normalizeIpAddress(String(proposedValues.office_ip_address || "")) === normalizeIpAddress(organizationSettingsDraft.office_ip_address)) {
      setNotice({ tone: "info", text: "입력한 IP는 이미 등록된 사무실 IP입니다. 변경 요청이 필요하지 않습니다." });
      return;
    }
    if (requestType === "workplace_location" && String(proposedValues.workplace_name || "").trim() === settingsDraft.workplace_name.trim()
      && Number(proposedValues.latitude) === settingsDraft.latitude && Number(proposedValues.longitude) === settingsDraft.longitude
      && Number(proposedValues.allowed_radius_meters) === settingsDraft.allowed_radius_meters) {
      setNotice({ tone: "info", text: "입력한 위치는 현재 사업장 설정과 같습니다. 변경 요청이 필요하지 않습니다." });
      return;
    }
    if (reason.length < 5) { setNotice({ tone: "warning", text: "변경할 값이 다른 경우에만 사유를 5자 이상 입력해 주세요." }); return; }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/organization-change-requests", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` }, body: JSON.stringify({ requestType, action: requestType === "org_admin_account" ? "replace" : "update", proposedValues, reason, targetProfileId: requestType === "org_admin_account" ? currentProfile?.id : null }) }).catch(() => null);
    setBusy(false);
    if (!response?.ok) {
      const result = await response?.json().catch(() => ({})) as { code?: string } | undefined;
      setNotice({ tone: result?.code === "UNCHANGED_VALUE" ? "info" : "error", text: result?.code === "UNCHANGED_VALUE" ? "현재 등록값과 같아 변경 요청이 필요하지 않습니다." : "변경 승인 요청을 보내지 못했습니다." });
      return;
    }
    form.reset();
    await loadOrganizationChangeRequests();
    setNotice({ tone: "success", text: "최고관리자에게 변경 승인 요청을 보냈습니다." });
  }

  async function reviewOrganizationChange(request: OrganizationChangeRequest, decision: "approved" | "rejected") {
    if (!supabase || effectiveRole !== "super_admin") return;
    const reviewNote = window.prompt(decision === "approved" ? "승인 메모를 입력해 주세요." : "반려 사유를 입력해 주세요.") || "";
    if (reviewNote.trim().length < 2) return;
    let temporaryPassword = "";
    if (decision === "approved" && request.request_type === "org_admin_account" && request.action === "replace") {
      temporaryPassword = window.prompt("새 기관관리자의 임시 비밀번호를 8자 이상, 영문, 숫자, 특수문자 조합으로 입력해 주세요.") || "";
      if (!isPrivilegedPassword(temporaryPassword)) { setNotice({ tone: "warning", text: "기관관리자 임시 비밀번호는 8자 이상이며 영문, 숫자, 특수문자를 모두 포함해야 합니다." }); return; }
    }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-review-organization-change", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` }, body: JSON.stringify({ requestId: request.id, decision, reviewNote, temporaryPassword }) }).catch(() => null);
    setBusy(false);
    if (!response?.ok) { setNotice({ tone: "error", text: "승인 요청을 처리하지 못했습니다." }); return; }
    await loadOrganizationChangeRequests();
    setNotice({ tone: "success", text: decision === "approved" ? "변경을 승인하고 적용했습니다." : "변경 요청을 반려했습니다." });
  }

  async function reopenOrganizationChange(request: OrganizationChangeRequest) {
    if (!supabase || effectiveRole !== "super_admin") return;
    const reason = window.prompt("이 기관 변경 요청을 다시 검토하는 이유를 입력해 주세요.") || "";
    if (reason.trim().length < 2) return;
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/organization-change-requests", { method: "PATCH", headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` }, body: JSON.stringify({ requestId: request.id, reason }) }).catch(() => null);
    setBusy(false);
    if (!response?.ok) { setNotice({ tone: "error", text: "기관 변경 요청을 재검토 상태로 바꾸지 못했습니다." }); return; }
    await loadOrganizationChangeRequests();
    setNotice({ tone: "success", text: "기관 변경 요청을 승인 대기 상태로 되돌렸습니다. 현재 적용된 설정은 다음 결정 전까지 유지됩니다." });
  }

  async function createOrganization(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin") return;
    const data = new FormData(form);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        orgCode: String(data.get("org_code") || ""),
        orgName: String(data.get("org_name") || ""),
        shortName: String(data.get("short_name") || ""),
        domain: String(data.get("domain") || ""),
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { organization?: Organization; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.organization) {
      setNotice({ tone: "error", text: result.code === "ORGANIZATION_EXISTS" ? "같은 기관 코드나 도메인이 이미 등록되어 있습니다." : "기관을 만들지 못했습니다." });
      return;
    }
    form.reset();
    await loadOrganizations(result.organization.id);
    setNotice({ tone: "success", text: `${result.organization.short_name} 기관을 만들었습니다.` });
  }

  async function createOrganizationAdmin(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const data = new FormData(form);
    const password = String(data.get("password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (!isPrivilegedPassword(password) || password !== confirmPassword) {
      setNotice({ tone: "warning", text: "기관관리자 임시 비밀번호는 8자 이상 영문, 숫자, 특수문자 조합이며 확인값과 같아야 합니다." });
      return;
    }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-create-org-admin", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        orgId: selectedOrgId,
        name: String(data.get("name") || ""),
        employeeNumber: String(data.get("employee_number") || ""),
        password,
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { ok?: boolean; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.ok) {
      setNotice({ tone: "error", text: result.code === "EMPLOYEE_NUMBER_EXISTS" ? "이미 다른 계정이 사용하는 사번입니다." : "기관 관리자 계정을 만들지 못했습니다." });
      return;
    }
    form.reset();
    await loadOrganizations(selectedOrgId);
    setNotice({ tone: "success", text: "선택한 기관의 관리자 계정을 만들었습니다. 관리자는 통합 로그인 화면에서 사번과 비밀번호를 입력합니다." });
  }

  async function updateOrganizationAdmin(form: HTMLFormElement, person: Profile): Promise<boolean> {
    if (!supabase || effectiveRole !== "super_admin") return false;
    const data = new FormData(form);
    const password = String(data.get("password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (password && (!isPrivilegedPassword(password) || password !== confirmPassword)) {
      setNotice({ tone: "warning", text: "기관관리자 새 비밀번호는 8자 이상 영문, 숫자, 특수문자 조합이며 확인값과 같아야 합니다." });
      return false;
    }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-org-admin-account", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        userId: person.id,
        name: String(data.get("name") || ""),
        employeeNumber: String(data.get("employee_number") || ""),
        department: String(data.get("department") || ""),
        password,
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { profile?: Profile; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.profile) {
      const text = result.code === "EMPLOYEE_NUMBER_EXISTS" ? "이미 다른 계정이 사용하는 사번입니다."
        : result.code === "INVALID_PASSWORD" ? "새 비밀번호가 계정 보안 기준에 맞지 않습니다."
              : result.code === "AUTH_PASSWORD_UPDATE_FAILED" ? "로그인 비밀번호를 바꾸지 못했습니다."
            : result.code === "PROFILE_UPDATE_FAILED" ? "로그인 계정은 확인했지만 기관관리자 정보를 저장하지 못했습니다. 다시 시도해 주세요."
              : `기관관리자 정보를 수정하지 못했습니다${result.code ? ` (${result.code})` : ""}.`;
      setNotice({ tone: "error", text });
      return false;
    }
    await loadOrganizations(person.org_id || selectedOrgId);
    setNotice({ tone: "success", text: `${result.profile.name} 기관관리자 정보를 최고관리자 권한으로 변경했습니다.` });
    return true;
  }

  async function deleteOrganizationAdmin(person: Profile): Promise<boolean> {
    if (!supabase || effectiveRole !== "super_admin") return false;
    if (!window.confirm(`${person.name} 기관관리자 계정을 삭제할까요?\n\n로그인은 즉시 차단하고 이메일과 사번은 다시 사용할 수 있게 합니다. 기존 승인 이력과 근태기록 연결은 보존됩니다.`)) return false;
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-org-admin-account", {
      method: "DELETE",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ userId: person.id }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { ok?: boolean; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.ok) {
      setNotice({ tone: "error", text: `기관관리자 계정을 삭제하지 못했습니다${result.code ? ` (${result.code})` : ""}.` });
      return false;
    }
    await loadOrganizations(person.org_id || selectedOrgId);
    setNotice({ tone: "success", text: `${person.name} 기관관리자 계정을 삭제했습니다. 기존 기록 연결은 보존됩니다.` });
    return true;
  }

  async function updateOrganization(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const values = new FormData(form);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        orgId: selectedOrgId,
        orgName: String(values.get("org_name") || ""),
        shortName: String(values.get("short_name") || ""),
        domain: String(values.get("domain") || ""),
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { organization?: Organization; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.organization) {
      setNotice({ tone: "error", text: result.code === "ORGANIZATION_EXISTS" ? "같은 도메인을 쓰는 기관이 이미 있습니다." : result.code === "BRANDING_SCHEMA_REQUIRED" ? "스테이징 데이터베이스에 브랜딩 SQL이 아직 적용되지 않아 저장할 수 없습니다." : `기관 정보를 수정하지 못했습니다${result.code ? ` (${result.code})` : ""}.` });
      return;
    }
    await loadOrganizations(result.organization.id);
    setNotice({ tone: "success", text: "기관 정보와 브랜딩을 수정했습니다." });
  }

  async function deactivateOrganization() {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const selected = organizations.find((item) => item.id === selectedOrgId);
    if (!selected || !window.confirm(`${selected.short_name} 기관을 사용 중지할까요?\n\n직원 로그인과 신규 기록은 막고, 기존 근태기록은 보존합니다.`)) return;
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      method: "DELETE",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ orgId: selectedOrgId }),
    }).catch(() => null);
    setBusy(false);
    if (!response?.ok) { setNotice({ tone: "error", text: "기관을 사용 중지하지 못했습니다." }); return; }
    await loadOrganizations(selectedOrgId);
    setNotice({ tone: "success", text: `${selected.short_name} 기관을 사용 중지했습니다. 기존 기록은 보존됩니다.` });
  }

  async function reactivateOrganization() {
    if (!supabase || effectiveRole !== "super_admin" || !selectedOrgId) return;
    const selected = organizations.find((item) => item.id === selectedOrgId);
    if (!selected) return;
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ scope: "status", orgId: selectedOrgId, isActive: true }),
    }).catch(() => null);
    setBusy(false);
    if (!response?.ok) { setNotice({ tone: "error", text: "기관을 다시 사용 상태로 바꾸지 못했습니다." }); return; }
    await loadOrganizations(selectedOrgId);
    setNotice({ tone: "success", text: `${selected.short_name} 기관을 다시 사용할 수 있습니다.` });
  }

  async function updateOrganizationBranding(form: HTMLFormElement) {
    if (!supabase || !currentProfile?.org_id || !["admin", "org_admin"].includes(effectiveRole)) return;
    const values = new FormData(form);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-organizations", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        scope: "branding",
        orgId: currentProfile.org_id,
        brandTitle: String(values.get("brand_title") || ""),
        brandDescription: String(values.get("brand_description") || ""),
        brandSubtitle: String(values.get("brand_subtitle") || ""),
        brandMark: String(values.get("brand_mark") || ""),
        brandLogoUrl: String(values.get("brand_logo_url") || ""),
        brandPrimaryColor: String(values.get("brand_primary_color") || ""),
        brandAccentColor: String(values.get("brand_accent_color") || ""),
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { organization?: TenantOrganization; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.organization) {
      setNotice({ tone: "error", text: result.code === "INVALID_INPUT" ? "색상이나 로고 주소 형식을 확인해 주세요." : "기관 브랜딩을 저장하지 못했습니다." });
      return;
    }
    setTenantOrganization(result.organization);
    setNotice({ tone: "success", text: "기관 화면 제목, 색상과 로고를 저장했습니다." });
  }

  async function uploadOrganizationLogo(file: File): Promise<string | null> {
    if (!supabase || !currentProfile?.org_id || !["admin", "org_admin"].includes(effectiveRole)) return null;
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
      setNotice({ tone: "warning", text: "로고는 PNG, JPG 또는 WEBP 파일만 올릴 수 있습니다." });
      return null;
    }
    if (file.size > 2 * 1024 * 1024) {
      setNotice({ tone: "warning", text: "로고 파일은 2MB 이하로 올려 주세요." });
      return null;
    }
    const body = new FormData();
    body.set("org_id", currentProfile.org_id);
    body.set("logo", file);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-upload-brand-logo", {
      method: "POST",
      headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body,
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { logoUrl?: string; organization?: TenantOrganization; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.logoUrl) {
      setNotice({ tone: "error", text: `로고 파일을 올리지 못했습니다${result.code ? ` (${result.code})` : ""}.` });
      return null;
    }
    if (result.organization) setTenantOrganization(result.organization);
    setNotice({ tone: "success", text: "기관 로고를 올리고 화면에 적용했습니다." });
    return result.logoUrl;
  }

  async function updateSuperAdminBranding(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin") return;
    const values = new FormData(form);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-super-admin-branding", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({
        brandTitle: String(values.get("brand_title") || ""),
        brandDescription: String(values.get("brand_description") || ""),
        brandSubtitle: String(values.get("brand_subtitle") || ""),
        brandMark: String(values.get("brand_mark") || ""),
        brandLogoUrl: String(values.get("brand_logo_url") || ""),
        brandPrimaryColor: String(values.get("brand_primary_color") || ""),
        brandAccentColor: String(values.get("brand_accent_color") || ""),
      }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { profile?: Profile; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.profile) {
      setNotice({ tone: "error", text: result.code === "BRANDING_SCHEMA_REQUIRED" ? "개발 DB에 최고관리자 브랜딩 SQL이 필요합니다." : "최고관리자 화면을 저장하지 못했습니다." });
      return;
    }
    setProfile(result.profile);
    setSuperAdminBranding(superAdminBrandingSource(result.profile));
    setNotice({ tone: "success", text: "최고관리자 전용 제목, 로고와 색상을 저장했습니다." });
  }

  async function updateSuperAdminEmployeeNumber(form: HTMLFormElement) {
    if (!supabase || effectiveRole !== "super_admin") return;
    const employeeNumber = String(new FormData(form).get("employee_number") || "").trim().toUpperCase();
    if (!/^[A-Z0-9-]{2,30}$/.test(employeeNumber)) { setNotice({ tone: "warning", text: "사번은 영문, 숫자, 하이픈을 사용해 2자 이상 입력해 주세요." }); return; }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-super-admin-account", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ employeeNumber }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { profile?: Profile; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.profile) {
      setNotice({ tone: "error", text: result.code === "EMPLOYEE_NUMBER_ALREADY_EXISTS" ? "이미 다른 계정에서 사용 중인 사번입니다." : "최고관리자 사번을 저장하지 못했습니다." });
      return;
    }
    setProfile(result.profile);
    setNotice({ tone: "success", text: "최고관리자 로그인 사번을 저장했습니다. 다음 로그인부터 새 사번을 사용할 수 있습니다." });
  }

  async function purgeExpiredAttendanceData() {
    if (!supabase || effectiveRole !== "super_admin") return;
    const currentYear = Number(currentDateKey().slice(0, 4));
    const deleteThroughYear = currentYear - 7;
    const keepFromYear = deleteThroughYear + 1;
    setBusy(true);
    const { data: preview, error: previewError } = await supabase.rpc("preview_attendance_retention_cleanup", { p_delete_through_year: deleteThroughYear });
    setBusy(false);
    if (previewError) { setNotice({ tone: "error", text: "삭제 대상 기록을 확인하지 못했습니다. 보존기간 관리 SQL 적용 여부를 확인해 주세요." }); return; }
    const counts = preview as { attendance_records?: number; correction_requests?: number; attendance_exceptions?: number; audit_logs?: number } | null;
    setRetentionPreview({ deleteThroughYear, keepFromYear, attendanceRecords: counts?.attendance_records || 0, correctionRequests: counts?.correction_requests || 0, attendanceExceptions: counts?.attendance_exceptions || 0, auditLogs: counts?.audit_logs || 0 });
  }

  async function confirmPurgeExpiredAttendanceData() {
    if (!supabase || effectiveRole !== "super_admin" || !retentionPreview) return;
    const { deleteThroughYear, keepFromYear } = retentionPreview;
    const confirmation = `${deleteThroughYear}년 이전 기록 영구 삭제`;
    setBusy(true);
    const { data: result, error } = await supabase.rpc("purge_attendance_retention_data", { p_delete_through_year: deleteThroughYear, p_confirmation: confirmation });
    setBusy(false);
    if (error) { setNotice({ tone: "error", text: `보존기간 경과 기록을 삭제하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` }); return; }
    setRetentionPreview(null);
    const deleted = result as { attendance_records?: number } | null;
    setNotice({ tone: "success", text: `${deleteThroughYear}년까지의 보존기간 경과 근태기록 ${deleted?.attendance_records || 0}건을 영구 삭제했습니다. ${keepFromYear}년 이후 기록은 유지됩니다.` });
    if (currentProfile) await loadRemoteData(currentProfile);
  }

  async function uploadSuperAdminLogo(file: File): Promise<string | null> {
    if (!supabase || effectiveRole !== "super_admin") return null;
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type) || file.size <= 0 || file.size > 2 * 1024 * 1024) {
      setNotice({ tone: "warning", text: "로고는 2MB 이하의 PNG, JPG 또는 WEBP 파일만 올릴 수 있습니다." });
      return null;
    }
    const body = new FormData();
    body.set("scope", "super_admin");
    body.set("logo", file);
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-upload-brand-logo", { method: "POST", headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` }, body }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { logoUrl?: string; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.logoUrl) {
      setNotice({ tone: "error", text: `최고관리자 로고를 올리지 못했습니다${result.code ? ` (${result.code})` : ""}.` });
      return null;
    }
    setSuperAdminBranding((current) => ({ ...current, brand_logo_url: result.logoUrl }));
    setNotice({ tone: "success", text: "최고관리자 전용 로고를 올렸습니다." });
    return result.logoUrl;
  }

  async function loadRemoteData(userProfile: Profile) {
    if (!supabase) return;
    if (userProfile.role === "super_admin") {
      setRecords([]); setProfiles([]); setRequests([]); setAuditLogs([]); setExceptions([]);
      setCompTimeBalances([]); setAnnualLeaveBalances([]); setCompTimeCredits([]); setMonthlyOvertimeAfterComp([]); setMonthClosing(null);
      if (!selectedOrgId) return;
      const { data: sessionData } = await supabase.auth.getSession();
      const response = await fetch(`/api/admin-organization-attendance?orgId=${encodeURIComponent(selectedOrgId)}&month=${encodeURIComponent(selectedMonth)}`, {
        headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
        cache: "no-store",
      }).catch(() => null);
      const result = response ? await response.json().catch(() => ({})) as {
        organization?: TenantOrganization; profiles?: Profile[]; records?: AttendanceRecord[];
        requests?: CorrectionRequest[]; exceptions?: AttendanceException[]; audits?: AuditLog[]; closing?: MonthClosing | null;
      } : {};
      if (!response?.ok) {
        setNotice({ tone: "error", text: "선택한 기관의 근태자료를 불러오지 못했습니다." });
        return;
      }
      setProfiles(result.profiles || []); setRecords(result.records || []); setRequests(result.requests || []);
      setExceptions(result.exceptions || []); setAuditLogs(result.audits || []); setMonthClosing(result.closing || null);
      return;
    }
    const from = `${selectedMonth}-01`;
    const untilDate = new Date(`${from}T00:00:00+09:00`);
    untilDate.setMonth(untilDate.getMonth() + 1);
    const until = KST_DATE.format(untilDate);
    const recordQuery = supabase.from("attendance_records_view").select("*").gte("work_date", from).lt("work_date", until).order("work_date", { ascending: false });
    const todayQuery = supabase.from("attendance_records_view").select("*").eq("employee_id", userProfile.id).eq("work_date", currentDateKey()).maybeSingle();
    const openRecordQuery = supabase.from("attendance_records_view").select("*").eq("employee_id", userProfile.id).not("clock_in_at", "is", null).is("clock_out_at", null).order("clock_in_at", { ascending: false }).limit(1).maybeSingle();
    const requestQuery = supabase.from("correction_requests_view").select("*").order("requested_at", { ascending: false });
    const workplaceQuery = supabase.from("workplaces").select("*").eq("is_active", true).limit(1).maybeSingle();
    const organizationQuery = supabase.from("organization_settings").select("*").eq("id", true).maybeSingle();
    const exceptionQuery = supabase.from("attendance_exceptions_view").select("*").is("cancelled_at", null).order("start_date", { ascending: false });
    const closingQuery = supabase.from("monthly_closings").select("*").eq("year", Number(selectedMonth.slice(0, 4))).eq("month", Number(selectedMonth.slice(5, 7))).maybeSingle();
    const balanceQuery = supabase.from("comp_time_balances_view").select("*");
    const annualBalanceQuery = supabase.from("annual_leave_balances_view").select("*");
    const creditQuery = supabase.from("comp_time_credit_details_view").select("*").order("expires_on");
    const overtimeAfterCompQuery = supabase.from("monthly_overtime_after_comp_view").select("*").eq("source_month", selectedMonth);
    const workPolicyQuery = supabase.from("organization_work_policies").select("*").maybeSingle();
    const shiftTemplateQuery = supabase.from("work_shift_templates").select("*").order("shift_name");
    const shiftAssignmentQuery = supabase.from("employee_shift_assignments").select("*").gte("work_date", from).lt("work_date", until).order("work_date");
    const [recordResult, todayResult, openRecordResult, requestResult, workplaceResult, organizationResult, exceptionResult, closingResult, balanceResult, annualBalanceResult, creditResult, overtimeAfterCompResult, workPolicyResult, shiftTemplateResult, shiftAssignmentResult] = await Promise.all([recordQuery, todayQuery, openRecordQuery, requestQuery, workplaceQuery, organizationQuery, exceptionQuery, closingQuery, balanceQuery, annualBalanceQuery, creditQuery, overtimeAfterCompQuery, workPolicyQuery, shiftTemplateQuery, shiftAssignmentQuery]);
    if (!recordResult.error) {
      const monthRecords = (recordResult.data || []) as AttendanceRecord[];
      const today = todayResult.data as AttendanceRecord | null;
      const openRecord = openRecordResult.data as AttendanceRecord | null;
      const additional: AttendanceRecord[] = [];
      for (const candidate of [today, openRecord]) if (candidate && !monthRecords.some((record) => record.id === candidate.id) && !additional.some((record) => record.id === candidate.id)) additional.push(candidate);
      setRecords([...additional, ...monthRecords]);
    }
    if (!requestResult.error) setRequests((requestResult.data || []) as CorrectionRequest[]);
    if (workplaceResult.data) { setWorkplace(workplaceResult.data as Workplace); setSettingsDraft(workplaceResult.data as Workplace); }
    if (organizationResult.data) {
      const normalized = normalizeOrganizationSettings(organizationResult.data as OrganizationSettings);
      setOrganizationSettingsDraft(normalized);
    }
    if (!exceptionResult.error) setExceptions((exceptionResult.data || []) as AttendanceException[]);
    if (!closingResult.error) setMonthClosing((closingResult.data as MonthClosing | null) || null);
    if (!balanceResult.error) setCompTimeBalances((balanceResult.data || []) as CompTimeBalance[]);
    if (!annualBalanceResult.error) setAnnualLeaveBalances((annualBalanceResult.data || []) as AnnualLeaveBalance[]);
    if (!creditResult.error) setCompTimeCredits((creditResult.data || []) as CompTimeCredit[]);
    if (!overtimeAfterCompResult.error) setMonthlyOvertimeAfterComp((overtimeAfterCompResult.data || []) as MonthlyOvertimeAfterComp[]);
    if (!workPolicyResult.error && workPolicyResult.data) setWorkPolicyDraft({ ...(workPolicyResult.data as OrganizationWorkPolicy), work_date_boundary_time: String(workPolicyResult.data.work_date_boundary_time).slice(0, 5) });
    if (!shiftTemplateResult.error) setShiftTemplates((shiftTemplateResult.data || []).map((item) => ({ ...item, start_time: String(item.start_time).slice(0, 5), end_time: String(item.end_time).slice(0, 5) })) as WorkShiftTemplate[]);
    if (!shiftAssignmentResult.error) setShiftAssignments((shiftAssignmentResult.data || []) as EmployeeShiftAssignment[]);
    if (isAdminRole(userProfile.role) || userProfile.can_view_reports) {
      const profilesQuery = supabase.from("profiles").select("*").order("is_active", { ascending: false }).order("name");
      const [profilesResult, auditResult] = await Promise.all([
        isAdminRole(userProfile.role) ? profilesQuery : profilesQuery.eq("is_active", true),
        supabase.from("attendance_audit_logs_view").select("*").gte("created_at", new Date(`${from}T00:00:00+09:00`).toISOString()).lt("created_at", new Date(`${until}T00:00:00+09:00`).toISOString()).order("created_at", { ascending: false }),
      ]);
      if (!profilesResult.error) setProfiles((profilesResult.data || []) as Profile[]);
      if (!auditResult.error) setAuditLogs((auditResult.data || []) as AuditLog[]);
    }
  }

  async function login(event: React.FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    setEmployeeView("today");
    setAdminView("organizations");
    setMenuOpen(false);
    setBusy(true); setLoginError("");
    const identifier = loginIdentifier.trim();
    const response = await fetch("/api/employee-login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifier, password: loginPassword }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { session?: { access_token: string; refresh_token: string }; organization?: TenantOrganization; code?: string } : {};
    if (!response?.ok || !result.session) {
      setLoginError(result.code === "PASSWORD_MIGRATION_FAILED"
        ? "기존 비밀번호 전환을 완료하지 못했습니다. 관리자에게 문의해 주세요."
        : "사번, 이메일 또는 비밀번호를 확인해 주세요.");
      setBusy(false);
      return;
    }
    if (result.organization) setTenantOrganization(result.organization);
    const { error } = await supabase.auth.setSession(result.session);
    if (error) setLoginError("로그인 정보를 연결하지 못했습니다. 다시 시도해 주세요.");
    setBusy(false);
  }

  async function resetPassword() {
    if (!supabase || !loginIdentifier.trim().includes("@")) { setLoginError("사번 로그인 계정의 비밀번호는 상위 관리자에게 초기화를 요청해 주세요."); return; }
    const { error } = await supabase.auth.resetPasswordForEmail(loginIdentifier.trim(), { redirectTo: window.location.origin });
    setLoginError(error ? "재설정 안내를 보내지 못했습니다. 잠시 후 다시 시도해 주세요." : "입력한 이메일로 비밀번호 재설정 안내를 보냈습니다.");
  }

  async function changeOwnPassword(form: HTMLFormElement) {
    if (!supabase || !currentProfile) return;
    const data = new FormData(form);
    const currentPassword = String(data.get("current_password") || "");
    const newPassword = String(data.get("new_password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (isAdminRole(effectiveRole) ? !isPrivilegedPassword(newPassword) : newPassword.length < 6) { setNotice({ tone: "warning", text: isAdminRole(effectiveRole) ? "관리자 비밀번호는 8자 이상이며 영문, 숫자, 특수문자를 모두 포함해야 합니다." : "새 비밀번호는 6자 이상 입력해 주세요." }); return; }
    if (newPassword !== confirmPassword) { setNotice({ tone: "warning", text: "새 비밀번호 확인이 일치하지 않습니다." }); return; }
    setBusy(true);
    if (!passwordRecovery) {
      const { error: verifyError } = await signInWithCompatiblePassword(supabase, currentProfile.email, currentPassword);
      if (verifyError) {
        setBusy(false);
        setNotice({ tone: "error", text: "현재 비밀번호가 맞지 않습니다." });
        return;
      }
    }
    const { error } = await supabase.auth.updateUser({ password: toSupabasePassword(newPassword) });
    setBusy(false);
    if (error) {
      const weakPassword = "code" in error && error.code === "weak_password";
      setNotice({ tone: "error", text: weakPassword ? "현재 Supabase 프로젝트의 비밀번호 기준을 충족하지 못했습니다. 다른 비밀번호로 다시 시도해 주세요." : "비밀번호를 변경하지 못했습니다. 다른 비밀번호로 다시 시도해 주세요." });
      return;
    }
    const { error: completionError } = await supabase.rpc("complete_required_password_change");
    if (completionError) {
      setNotice({ tone: "error", text: "비밀번호는 변경됐지만 필수 변경 상태를 완료하지 못했습니다. 다시 로그인한 뒤 한 번 더 변경해 주세요." });
      return;
    }
    setProfile((profile) => profile ? { ...profile, must_change_password: false } : profile);
    form.reset();
    setNotice({ tone: "success", text: "비밀번호가 변경되었습니다. 다음 로그인부터 새 비밀번호를 사용하세요." });
    setPasswordOpen(false);
    setPasswordRecovery(false);
  }

  async function resetEmployeePassword(form: HTMLFormElement) {
    if (!supabase || !currentProfile || !resetPasswordTarget || !["admin", "org_admin"].includes(effectiveRole)) return;
    const data = new FormData(form);
    const adminPassword = String(data.get("admin_password") || "");
    const newPassword = String(data.get("new_password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (newPassword.length < 6) { setNotice({ tone: "warning", text: "직원 임시 비밀번호는 6자 이상 입력해 주세요." }); return; }
    if (newPassword !== confirmPassword) { setNotice({ tone: "warning", text: "임시 비밀번호 확인이 일치하지 않습니다." }); return; }
    setBusy(true);
    const { error: verifyError } = await signInWithCompatiblePassword(supabase, currentProfile.email, adminPassword);
    if (verifyError) {
      setBusy(false);
      setNotice({ tone: "error", text: "관리자 비밀번호가 맞지 않습니다." });
      return;
    }
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-reset-password", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ userId: resetPasswordTarget.id, password: newPassword }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { ok?: boolean; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.ok) {
      const text = result.code === "RESET_NOT_CONFIGURED"
        ? "직원 비밀번호 초기화용 서버 비밀키가 아직 설정되지 않았습니다. 기관 호스팅 설정에서 비밀키를 등록해 주세요."
        : result.code === "ORG_ADMIN_REQUIRED" ? "기관 관리자만 자기 기관 직원의 비밀번호를 초기화할 수 있습니다."
          : "직원 비밀번호를 초기화하지 못했습니다. 잠시 후 다시 시도해 주세요.";
      setNotice({ tone: "error", text });
      return;
    }
    form.reset();
    setResetPasswordTarget(null);
    setNotice({ tone: "success", text: `${resetPasswordTarget.name}님의 임시 비밀번호를 설정했습니다. 직원에게 안전하게 전달해 주세요.` });
    await loadRemoteData(currentProfile);
  }

  async function createEmployee(form: HTMLFormElement) {
    if (!supabase || !currentProfile || !["admin", "org_admin"].includes(effectiveRole)) return;
    const data = new FormData(form);
    const adminPassword = String(data.get("admin_password") || "");
    const password = String(data.get("password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (password.length < 6 || password !== confirmPassword) { setNotice({ tone: "warning", text: "직원 임시 비밀번호는 6자 이상이며 확인값과 같아야 합니다." }); return; }
    setBusy(true);
    const { error: verifyError } = await signInWithCompatiblePassword(supabase, currentProfile.email, adminPassword);
    if (verifyError) { setBusy(false); setNotice({ tone: "error", text: "관리자 비밀번호가 맞지 않습니다." }); return; }
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-create-employee", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ name: String(data.get("name") || ""), department: String(data.get("department") || ""), password }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { ok?: boolean; code?: string; profile?: Profile } : {};
    setBusy(false);
    if (!response?.ok || !result.ok) {
      const text = result.code === "EMPLOYEE_NUMBER_CREATE_FAILED" ? "새 사번을 발급하지 못했습니다. 사번 보완 SQL 적용 여부를 확인해 주세요." : result.code === "CREATE_NOT_CONFIGURED" ? "직원 계정 생성용 서버 비밀키가 설정되지 않았습니다." : "직원 계정을 만들지 못했습니다. 입력값과 서버 설정을 확인해 주세요.";
      setNotice({ tone: "error", text }); return;
    }
    form.reset(); setEmployeeCreateOpen(false);
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: `새 직원 계정을 만들었습니다. 발급 사번은 ${result.profile?.employee_number || "직원 목록"}입니다.` });
  }

  async function updateEmployee(form: HTMLFormElement) {
    if (!supabase || !currentProfile || !editingEmployee || !["admin", "org_admin", "super_admin"].includes(effectiveRole)) return;
    const data = new FormData(form);
    const employeeNumber = String(data.get("employee_number") || "").trim().toUpperCase();
    const password = String(data.get("password") || "");
    const confirmPassword = String(data.get("confirm_password") || "");
    if (!/^[A-Z0-9-]{2,30}$/.test(employeeNumber)) { setNotice({ tone: "warning", text: "사번은 영문, 숫자, 하이픈만 사용할 수 있습니다." }); return; }
    if (password && (password.length < 6 || password !== confirmPassword)) { setNotice({ tone: "warning", text: "새 임시 비밀번호는 6자 이상이며 확인값과 같아야 합니다." }); return; }
    setBusy(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const response = await fetch("/api/admin-employee-account", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
      body: JSON.stringify({ userId: editingEmployee.id, name: String(data.get("name") || ""), employeeNumber, department: String(data.get("department") || ""), password }),
    }).catch(() => null);
    const result = response ? await response.json().catch(() => ({})) as { ok?: boolean; code?: string } : {};
    setBusy(false);
    if (!response?.ok || !result.ok) {
      setNotice({ tone: "error", text: result.code === "EMPLOYEE_NUMBER_EXISTS" ? "이미 다른 직원이 사용하는 사번입니다." : result.code === "AUTH_PASSWORD_UPDATE_FAILED" ? "직원 임시 비밀번호를 바꾸지 못했습니다." : "직원 정보를 수정하지 못했습니다." });
      return;
    }
    setEditingEmployee(null);
    if (effectiveRole === "super_admin") await loadOrganizations(selectedOrgId);
    else await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: `직원 정보를 수정했습니다. 다음 로그인부터 새 사번${password ? "과 새 임시 비밀번호" : ""}를 사용합니다. 기존 근태기록은 그대로 유지됩니다.` });
  }

  async function setEmployeeActive(person: Profile, active: boolean) {
    if (!supabase || !currentProfile || !["admin", "org_admin"].includes(effectiveRole)) return;
    if (!window.confirm(active ? `${person.name}님의 계정을 재활성화할까요? 다시 로그인할 수 있게 됩니다.` : `${person.name}님을 퇴사 처리할까요? 로그인은 차단되지만 기존 기록은 보존됩니다.`)) return;
    const { error } = await supabase.rpc("admin_set_employee_active", { p_employee_id: person.id, p_active: active });
    if (error) { setNotice({ tone: "error", text: `직원 상태를 변경하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 직원관리 보완 SQL을 실행해 주세요.` }); return; }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: active ? `${person.name}님의 계정을 재활성화했습니다.` : `${person.name}님을 퇴사 처리했습니다. 기존 기록은 그대로 보존됩니다.` });
  }

  const todayRecord = useMemo(() => records.find((record) => record.employee_id === currentProfile?.id && record.work_date === currentDateKey()), [records, currentProfile]);
  const openRecord = useMemo(() => records.find((record) => record.employee_id === currentProfile?.id && record.clock_in_at && !record.clock_out_at), [records, currentProfile]);
  const todayException = useMemo(() => exceptions.find((item) => item.employee_id === currentProfile?.id && !item.cancelled_at && item.start_date <= currentDateKey() && item.end_date >= currentDateKey()), [exceptions, currentProfile]);
  const myRecords = useMemo(() => records.filter((record) => record.employee_id === currentProfile?.id && record.work_date.startsWith(selectedMonth)), [records, currentProfile, selectedMonth]);
  const myExceptions = useMemo(() => {
    const firstDay = `${selectedMonth}-01`;
    const next = new Date(`${firstDay}T12:00:00+09:00`);
    next.setMonth(next.getMonth() + 1);
    const nextMonth = KST_DATE.format(next);
    return exceptions.filter((item) => item.employee_id === currentProfile?.id && !item.cancelled_at && item.start_date < nextMonth && item.end_date >= firstDay);
  }, [exceptions, currentProfile, selectedMonth]);
  const myRequests = useMemo(() => requests.filter((request) => request.employee_id === currentProfile?.id), [requests, currentProfile]);
  const activeEmergencyRequest = useMemo(() => myRequests.find((request) => request.request_type === "emergency_support" && ["pending", "more_info"].includes(request.status) && !request.end_time), [myRequests]);
  const allMonthRows = useMemo(() => records.filter((record) => record.work_date.startsWith(selectedMonth)), [records, selectedMonth]);
  const monthlyRows = useMemo(() => records.filter((record) => record.work_date.startsWith(selectedMonth)
    && (employeeFilter === "all" || record.employee_id === employeeFilter)
    && (statusFilter === "all" || record.attendance_status === statusFilter)), [records, selectedMonth, employeeFilter, statusFilter]);

  function startClock(action: "clock_in" | "clock_out") {
    if (todayException && !(action === "clock_out" && openRecord?.clock_in_at)) {
      setNotice({ tone: "info", text: `오늘은 ${EXCEPTION_TYPE_LABEL[todayException.exception_type] || "승인 예외 근무"} 기간으로 등록되어 출퇴근 버튼을 누르지 않아도 됩니다.` });
      return;
    }
    if ((action === "clock_in" && openRecord?.clock_in_at) || (action === "clock_out" && todayRecord?.clock_out_at)) {
      setNotice({ tone: "warning", text: action === "clock_in" ? "아직 퇴근하지 않은 출근 기록이 있습니다. 먼저 퇴근을 기록해 주세요." : "오늘 퇴근은 이미 기록됐습니다." });
      return;
    }
    if (action === "clock_out" && !openRecord?.clock_in_at) {
      setNotice({ tone: "warning", text: "출근 기록이 없어 퇴근할 수 없습니다. 먼저 출근시각 수정 신청을 제출해 주세요." });
      return;
    }
    setPendingClockAction(action);
    if (!hasLocationConsent) setConsentOpen(true);
    else void executeClock(action);
  }

  async function executeClock(action: "clock_in" | "clock_out") {
    if (!currentProfile) return;
    setConsentOpen(false); setBusy(true); setNotice({ tone: "info", text: "현재 위치를 확인하고 있습니다. 이 화면을 잠시 유지해 주세요." });
    const [location, currentIp] = await Promise.all([
      requestCurrentLocation(workplace),
      fetchClientIp(),
    ]);
    const registeredOfficeIp = normalizeIpAddress(organizationSettingsDraft.office_ip_address);
    const currentOfficeIp = normalizeIpAddress(currentIp);
    const officeIpMatchedBeforeSubmit = Boolean(registeredOfficeIp && currentOfficeIp && registeredOfficeIp === currentOfficeIp);
    const checkedLocation: LocationResult = officeIpMatchedBeforeSubmit ? {
      ...location,
      status: "inside",
      message: "사무실 공인 IP가 확인됐습니다. GPS 오차와 관계없이 사무실 근무로 처리합니다.",
    } : location;
    let recordedLocation: LocationResult = checkedLocation;
    let recordedIpMatched = officeIpMatchedBeforeSubmit;
    setLocationResult(checkedLocation);
    const needsReason = !officeIpMatchedBeforeSubmit && location.status !== "inside";
    const desktopLowAccuracy = location.status === "low_accuracy" && isLikelyDesktop();
    let reason = "";
    if (needsReason && desktopLowAccuracy) {
      const confirmed = window.confirm(`${location.message}\n\nPC에서는 Wi-Fi와 네트워크 정보로 위치를 추정해 오차가 크게 표시될 수 있습니다. 사무실 PC 기록으로 제출하시겠습니까?`);
      if (confirmed) reason = `사무실 PC에서 기록, 위치 측정 오차 ${location.accuracy ?? "확인 불가"}m`;
    } else if (needsReason) {
      reason = window.prompt(`${location.message}\n\n사업장 밖에서 기록하는 사유를 입력해 주세요.\n예: 외부 일정, 교육, 회의, 출장, 상담 또는 동행, 아웃리치, 기타`) || "";
    }
    if (needsReason && !reason?.trim()) {
      setBusy(false); setNotice({ tone: "warning", text: "위치 확인이 어려운 경우에는 사유를 입력해야 기록을 제출할 수 있습니다." }); return;
    }
    try {
      if (supabase) {
        const { data: sessionData } = await supabase.auth.getSession();
        const accessToken = sessionData.session?.access_token;
        if (!accessToken) throw Object.assign(new Error("AUTH_REQUIRED"), { code: "AUTH_REQUIRED" });
        const response = await fetch("/api/clock-attendance", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
          body: JSON.stringify({
            action,
            latitude: location.latitude,
            longitude: location.longitude,
            accuracy: location.accuracy,
            locationStatus: location.status,
            note: reason || "",
            idempotencyKey: crypto.randomUUID(),
          }),
        });
        const result = await response.json().catch(() => ({})) as { ok?: boolean; code?: string; message?: string; recordId?: string; locationStatus?: LocationResult["status"]; distance?: number | null; ipMatched?: boolean };
        if (!response.ok || !result.ok || !result.recordId) throw Object.assign(new Error(result.message || result.code || "CLOCK_FAILED"), { code: result.code || "CLOCK_FAILED" });
        recordedIpMatched = Boolean(result.ipMatched);
        recordedLocation = {
          ...location,
          status: result.locationStatus || location.status,
          distance: typeof result.distance === "number" ? result.distance : location.distance,
          message: result.ipMatched
            ? "사무실 고정 IP가 서버에서 확인됐습니다. GPS 오차와 관계없이 사무실 근무로 기록했습니다."
            : result.locationStatus === "inside" ? "사업장 반경 안에서 기록했습니다." : location.message,
        };
        setLocationResult(recordedLocation);
        await loadRemoteData(currentProfile);
      } else {
        const timestamp = new Date().toISOString();
        setRecords((previous) => {
          const existing = previous.find((record) => record.employee_id === currentProfile.id && record.work_date === currentDateKey());
          if (existing) return previous.map((record) => record.id === existing.id ? {
            ...record,
            clock_out_at: timestamp,
            clock_out_accuracy: location.accuracy,
            clock_out_distance: location.distance,
            clock_out_location_status: location.status,
            clock_out_ip_address: null,
            clock_out_ip_matched: false,
            attendance_status: location.status === "inside" ? "normal" : "admin_review",
            note: reason || record.note,
          } : record);
          return [{
            id: `demo-${Date.now()}`, employee_id: currentProfile.id, employee_name: currentProfile.name,
            work_date: currentDateKey(), work_type: "office", clock_in_at: timestamp, clock_out_at: null,
            clock_in_accuracy: location.accuracy, clock_in_distance: location.distance, clock_in_location_status: location.status,
            clock_in_ip_address: null, clock_in_ip_matched: false,
            clock_out_accuracy: null, clock_out_distance: null, clock_out_location_status: "not_checked",
            attendance_status: location.status === "inside" ? "working" : "admin_review", note: reason || "", is_closed: false,
          }, ...previous];
        });
      }
      const place = attendancePlaceLabel(action, recordedLocation.status, recordedIpMatched);
      setNotice({ tone: recordedLocation.status === "inside" ? "success" : "warning", text: `${place}으로 기록됐습니다. ${recordedLocation.message}` });
    } catch (error) {
      if (supabase && isClockAuthenticationError(error)) {
        setProfile(null); setDataReady(false);
        setLoginError("로그인 유지 정보가 만료되었습니다. 다시 로그인한 뒤 출퇴근을 기록해 주세요.");
        await supabase.auth.signOut({ scope: "local" });
      } else {
        setNotice({ tone: "error", text: clockErrorMessage(error, action) });
        if (supabase) void loadRemoteData(currentProfile);
      }
    } finally { setBusy(false); setPendingClockAction(null); }
  }

  async function installApp() {
    if (!installPrompt) { setInstallGuideOpen(true); return; }
    await installPrompt.prompt();
    const choice = await installPrompt.userChoice;
    if (choice.outcome === "accepted") setInstallPrompt(null);
  }

  async function acceptLocationConsent() {
    setHasLocationConsent(true);
    if (supabase && currentProfile) {
      await supabase.from("location_consents").upsert({
        employee_id: currentProfile.id,
        notice_version: "2026-08-v2",
        notice_text: "출퇴근 사실과 근무 장소 확인을 위해 출근 또는 퇴근 기록 버튼을 누르는 시점의 위치정보와 공인 IP 주소를 수집합니다. 이 정보는 버튼을 누르는 순간에만 확인하며, 근무시간 중 이동경로나 실시간 위치를 추적하지 않습니다.",
        consented_at: new Date().toISOString(),
        withdrawn_at: null,
      }, { onConflict: "employee_id,notice_version" });
    }
    if (pendingClockAction) await executeClock(pendingClockAction);
  }

  async function submitCorrection(form: HTMLFormElement) {
    if (!currentProfile) return;
    const data = new FormData(form);
    const targetDate = String(data.get("target_date"));
    const record = records.find((item) => item.employee_id === currentProfile.id && item.work_date === targetDate);
    const requestType = String(data.get("request_type"));
    const isTimeCorrection = requestType === "clock_in_at" || requestType === "clock_out_at";
    const endDate = isTimeCorrection || requestType === "overtime" ? targetDate : String(data.get("end_date"));
    const startTime = isTimeCorrection ? null : String(data.get("start_time"));
    const endTime = isTimeCorrection ? null : String(data.get("end_time"));
    const calculatedMinutes = isTimeCorrection ? 0 : calculateRequestedMinutes(requestType, targetDate, endDate, startTime || "", endTime || "");
    const requestedValue = isTimeCorrection ? String(data.get("requested_value")) : String(calculatedMinutes);
    if (requestType === "comp_time") {
      const available = compTimeBalances.find((item) => item.employee_id === currentProfile.id)?.available_comp_time_minutes || 0;
      if (calculatedMinutes > available) { setNotice({ tone: "warning", text: `대체휴무 잔액은 ${formatMinutes(available)}입니다. 잔액을 넘겨 신청할 수 없습니다.` }); return; }
    }
    if (requestType === "annual_leave") {
      const balance = annualLeaveBalances.find((item) => item.employee_id === currentProfile.id && item.valid_from <= targetDate && item.valid_to >= endDate);
      if (!balance) { setNotice({ tone: "warning", text: "이 기간에 적용되는 연차 부여내역이 없습니다. 관리자에게 연차 기간과 수량 등록을 요청해 주세요." }); return; }
      if (calculatedMinutes > balance.remaining_minutes) { setNotice({ tone: "warning", text: `연차 잔액은 ${Number((balance.remaining_minutes / 480).toFixed(3))}일입니다. 잔액을 넘겨 신청할 수 없습니다.` }); return; }
    }
    if (!isTimeCorrection && calculatedMinutes <= 0) { setNotice({ tone: "warning", text: requestType === "emergency_support" ? "긴급지원의 실제 시작과 종료 일시를 확인해 주세요. 자정을 넘긴 경우 종료일을 다음 날로 선택해 주세요." : "시작일시와 종료일시를 확인해 주세요. 점심시간 12시부터 13시, 주말과 공휴일은 사용시간에서 제외됩니다." }); return; }
    if (requestType === "emergency_support" && overlappingEmergencyRequests(requests, currentProfile.id, targetDate, endDate, startTime || "", endTime || "").length > 0) { setNotice({ tone: "warning", text: "이미 등록된 긴급지원 시간과 겹칩니다. 기존 기록의 실제시간을 확인한 뒤 다시 입력해 주세요." }); return; }
    const newRequest: CorrectionRequest = {
      id: crypto.randomUUID(), attendance_record_id: record?.id || null, employee_id: currentProfile.id,
      employee_name: currentProfile.name, target_date: targetDate, end_date: endDate, start_time: startTime, end_time: endTime,
      calculated_minutes: calculatedMinutes, approved_minutes: 0, request_subtype: String(data.get("request_subtype") || ""), request_type: requestType,
      before_value: record ? JSON.stringify(record) : "기록 없음", requested_value: requestedValue,
      reason: String(data.get("reason")), status: "pending", reviewer_comment: "", requested_at: new Date().toISOString(), reviewed_at: null,
    };
    if (supabase) {
      const { error } = await supabase.from("correction_requests").insert({
        attendance_record_id: newRequest.attendance_record_id, employee_id: newRequest.employee_id,
        target_date: newRequest.target_date, request_type: newRequest.request_type,
        end_date: newRequest.end_date, start_time: newRequest.start_time, end_time: newRequest.end_time,
        request_subtype: newRequest.request_subtype, before_value: newRequest.before_value,
        requested_value: newRequest.requested_value, reason: newRequest.reason,
      });
      if (error) { setNotice({ tone: "error", text: `요청을 저장하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 통합 요청 데이터베이스 보완 SQL 적용 여부와 입력 내용을 확인해 주세요.` }); return; }
      await loadRemoteData(currentProfile);
    } else setRequests((previous) => [newRequest, ...previous]);
    setCorrectionOpen(false); setEmployeeEmergencyWorkOpen(false); setNotice({ tone: "success", text: "요청을 제출했습니다. 처리 상태와 승인 시각은 요청 처리상태 화면에서 확인할 수 있습니다." });
  }

  async function confirmAttendanceRecord(record: AttendanceRecord) {
    const comment = window.prompt("확인한 내용이나 사유를 입력해 주세요. 예: 사무실 IP 일치 확인, 외부 출근 사유 확인") || "";
    if (comment.trim().length < 2) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_confirm_attendance_record", { p_record_id: record.id, p_comment: comment });
      if (error) {
        const detail = error.message.includes("ADMIN_REQUIRED") ? "현재 계정에 기관관리자 권한이 없습니다."
          : error.message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관의 기록은 처리할 수 없습니다."
            : error.message.includes("MONTH_CLOSED") ? "마감된 달의 기록은 최고관리자만 처리할 수 있습니다."
              : error.message.includes("RECORD_NOT_REVIEWABLE") ? "이미 처리됐거나 확인 대상이 아닌 기록입니다."
                : "근태 확인 보완 SQL 적용 여부를 확인해 주세요.";
        setNotice({ tone: "error", text: `확인 처리를 저장하지 못했습니다. ${detail}` }); return;
      }
      if (currentProfile) await loadRemoteData(currentProfile);
    } else {
      setRecords((previous) => previous.map((item) => item.id === record.id ? { ...item, attendance_status: item.clock_out_at ? "normal" : "working", changed: true } : item));
    }
    setNotice({ tone: "success", text: "관리자 확인을 완료했습니다. 처리 내용은 변경 이력에 남았습니다." });
  }

  async function applyLeaveToAttendanceRecord(record: AttendanceRecord, form: HTMLFormElement) {
    const data = new FormData(form);
    const requestType = String(data.get("request_type") || "");
    if (!["annual_leave", "comp_time", "special_leave", "sick_leave", "other_leave"].includes(requestType)) { setNotice({ tone: "warning", text: "반영할 휴가 종류를 선택해 주세요." }); return; }
    const defaultStart = record.clock_out_at ? formatTimeInput(record.clock_out_at) : organizationSettingsDraft.default_start_time.slice(0, 5);
    const startTime = String(data.get("start_time") || defaultStart);
    const endTime = String(data.get("end_time") || organizationSettingsDraft.default_end_time.slice(0, 5));
    if (!/^\d{2}:\d{2}$/.test(endTime) || timeToMinutes(endTime) <= timeToMinutes(startTime)) { setNotice({ tone: "warning", text: "종료시각은 시작시각보다 늦어야 합니다." }); return; }
    const requestSubtype = ["special_leave", "other_leave"].includes(requestType) ? String(data.get("request_subtype") || "") : "";
    if (["special_leave", "other_leave"].includes(requestType) && requestSubtype.trim().length < 2) return;
    const comment = String(data.get("comment") || "");
    if (comment.trim().length < 5) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_apply_leave_to_attendance_record", {
        p_record_id: record.id,
        p_request_type: requestType,
        p_start_time: startTime,
        p_end_time: endTime,
        p_request_subtype: requestSubtype,
        p_comment: comment,
      });
      if (error) { setNotice({ tone: "error", text: `휴가 또는 대체휴무를 반영하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.${error.code === "42703" && error.message ? ` 서버 세부내용: ${error.message}` : ""} 데이터베이스 보완 SQL 적용 여부를 확인해 주세요.` }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    }
    setLeaveApplyingRecord(null);
    setNotice({ tone: "success", text: "관리자 확인 내용을 휴가 또는 대체휴무로 반영했습니다. 월별 현황과 출근부에도 표시됩니다." });
  }

  async function createAttendanceRecord(form: HTMLFormElement) {
    if (!currentProfile) return;
    const data = new FormData(form);
    const employeeIds = data.getAll("employee_id").map(String).filter(Boolean);
    const payload = {
      p_employee_ids: employeeIds,
      p_work_date: String(data.get("work_date") || ""),
      p_clock_in_time: String(data.get("clock_in_time") || ""),
      p_clock_out_time: String(data.get("clock_out_time") || ""),
      p_reason: String(data.get("reason") || ""),
    };
    if (employeeIds.length === 0 || !payload.p_work_date || !payload.p_clock_in_time || !payload.p_clock_out_time) { setNotice({ tone: "warning", text: "직원을 한 명 이상 선택하고 날짜, 출근시각과 퇴근시각을 모두 입력해 주세요." }); return; }
    if (timeToMinutes(payload.p_clock_out_time) <= timeToMinutes(payload.p_clock_in_time)) { setNotice({ tone: "warning", text: "퇴근시각은 출근시각보다 늦어야 합니다." }); return; }
    if (payload.p_reason.trim().length < 5) { setNotice({ tone: "warning", text: "관리자 직접 등록 사유를 5자 이상 입력해 주세요." }); return; }
    let batchResult: { created_count?: number; skipped_names?: string[] } = {};
    if (supabase) {
      const { data: result, error } = await supabase.rpc("admin_create_attendance_records", payload);
      if (error) {
        const message = String(error.message || "");
        setNotice({ tone: "error", text: message.includes("MONTH_CLOSED") ? "월 마감된 날짜에는 기록을 추가할 수 없습니다. 최고관리자는 월 마감을 해제한 뒤 추가해 주세요." : message.includes("ORGANIZATION_ACCESS_DENIED") ? "선택한 직원이 현재 관리 기관 소속이 아닙니다." : message.includes("RECORD_ALREADY_EXISTS") ? "같은 날짜에 이미 근무기록이 있습니다." : `근무기록을 추가하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요.` });
        return;
      }
      batchResult = (result || {}) as typeof batchResult;
      await loadRemoteData(currentProfile);
    }
    setAttendanceCreateOpen(false);
    const createdCount = batchResult.created_count ?? employeeIds.length;
    setNotice({ tone: createdCount === 0 ? "info" : "success", text: createdCount === 0 && batchResult.skipped_names?.length ? `이미 출퇴근 근무기록이 있어 새 기록을 만들지 않았습니다: ${batchResult.skipped_names.join(", ")}. 긴급지원 기록은 별도로 유지됩니다. 일반 근무시간은 해당 날짜의 수정 버튼에서 바꿔 주세요.` : `${createdCount}명의 근무기록을 추가했습니다.${batchResult.skipped_names?.length ? ` 기존 기록이 있어 제외된 직원: ${batchResult.skipped_names.join(", ")}` : ""} 관리자 직접 등록 사실과 사유가 변경 이력에 남습니다.` });
  }

  async function createEmergencySupportWork(form: HTMLFormElement) {
    if (!supabase || !currentProfile || !isAdminRole(effectiveRole)) return;
    const client = supabase;
    const data = new FormData(form);
    const employeeIds = data.getAll("employee_id").map(String).filter(Boolean);
    const sharedPayload = {
      p_start_date: String(data.get("start_date") || ""),
      p_end_date: String(data.get("end_date") || ""),
      p_start_time: String(data.get("start_time") || ""),
      p_end_time: String(data.get("end_time") || ""),
      p_reason: String(data.get("reason") || ""),
    };
    const minutes = calculateRequestedMinutes("emergency_support", sharedPayload.p_start_date, sharedPayload.p_end_date, sharedPayload.p_start_time, sharedPayload.p_end_time);
    if (employeeIds.length === 0 || minutes <= 0 || sharedPayload.p_reason.trim().length < 5) { setNotice({ tone: "warning", text: "직원을 한 명 이상 선택하고, 실제 시작과 종료 일시, 5자 이상의 사유를 입력해 주세요. 긴급지원 근무는 최대 24시간까지 등록할 수 있습니다." }); return; }
    const overlappingNames = employeeIds.filter((employeeId) => overlappingEmergencyRequests(requests, employeeId, sharedPayload.p_start_date, sharedPayload.p_end_date, sharedPayload.p_start_time, sharedPayload.p_end_time).length > 0).map((employeeId) => profiles.find((person) => person.id === employeeId)?.name || "미확인 직원");
    if (overlappingNames.length > 0) { setNotice({ tone: "warning", text: `이미 등록된 긴급지원 시간과 겹칩니다: ${overlappingNames.join(", ")}. 기존 기록의 시간을 확인한 뒤 다시 등록해 주세요.` }); return; }
    setBusy(true);
    const results = await Promise.all(employeeIds.map((employeeId) => client.rpc("admin_create_emergency_support_work", { ...sharedPayload, p_employee_id: employeeId })));
    setBusy(false);
    const failedResults = employeeIds.map((id, index) => ({ id, error: results[index].error })).filter((item) => Boolean(item.error));
    if (failedResults.length) {
      const failureDetails = failedResults.map(({ id, error }) => {
        const name = profiles.find((person) => person.id === id)?.name || "미확인 직원";
        const message = String(error?.message || "");
        const detail = message.includes("EMERGENCY_SUPPORT_TIME_OVERLAP") ? "기존 긴급지원 시간과 겹칩"
          : message.includes("MONTH_CLOSED") ? "해당 월이 마감됨"
            : message.includes("EMERGENCY_SUPPORT_DISABLED") ? "기관의 긴급지원 기능이 꺼져 있음"
              : message.includes("EMPLOYEE_NOT_FOUND") ? "활성 직원 계정을 확인할 수 없음"
                : message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관 직원이거나 기관 권한이 맞지 않음"
                  : message.includes("INVALID_EMERGENCY_SUPPORT_RANGE") ? "종료일시가 시작일시보다 빠르거나 24시간을 초과함"
                    : error?.code === "23514" ? "데이터베이스의 긴급지원 유형 허용 규칙이 오래됨"
                      : `확인하지 못한 데이터베이스 오류${error?.code ? ` ${error.code}` : ""}`;
        return `${name}: ${detail}`;
      });
      setNotice({ tone: "error", text: `긴급지원 근무를 등록하지 못했습니다. ${failureDetails.join(" / ")}` });
      await loadRemoteData(currentProfile);
      return;
    }
    form.reset();
    setEmergencyWorkOpen(false);
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: `${employeeIds.length}명의 긴급지원 근무 ${formatMinutes(minutes)}을 관리자 확인 완료 상태로 등록했습니다.` });
  }

  async function startEmergencySupportWork(form: HTMLFormElement) {
    if (!supabase || !currentProfile) return;
    const reason = String(new FormData(form).get("reason") || "").trim();
    if (reason.length < 5) { setNotice({ tone: "warning", text: "개인정보 없이 긴급지원 업무를 5자 이상 입력해 주세요." }); return; }
    setBusy(true);
    const { error } = await supabase.rpc("start_emergency_support_work", { p_reason: reason });
    setBusy(false);
    if (error) {
      const message = String(error.message || "");
      setNotice({ tone: "error", text: message.includes("EMERGENCY_SUPPORT_ALREADY_RUNNING") ? "이미 진행 중인 긴급지원 기록이 있습니다." : message.includes("EMERGENCY_SUPPORT_TIME_OVERLAP") ? "이미 등록된 긴급지원 시간과 겹칩니다. 기존 기록의 시간을 먼저 확인해 주세요." : "긴급지원 시작을 기록하지 못했습니다. 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요." });
      return;
    }
    setEmployeeEmergencyWorkOpen(false);
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "긴급지원 시작시각을 기록했습니다. 출근과 퇴근 기록은 별도로 유지됩니다." });
  }

  async function finishEmergencySupportWork(form: HTMLFormElement, request: CorrectionRequest) {
    if (!supabase || !currentProfile) return;
    const completionNote = String(new FormData(form).get("completion_note") || "").trim();
    setBusy(true);
    const { data: minutes, error } = await supabase.rpc("finish_emergency_support_work", { p_request_id: request.id, p_completion_note: completionNote });
    setBusy(false);
    if (error) {
      const message = String(error.message || "");
      setNotice({ tone: "error", text: message.includes("INVALID_EMERGENCY_SUPPORT_RANGE") ? "긴급지원은 시작 후 24시간 안에 종료해야 합니다. 실제 시간을 직접 입력해 주세요." : message.includes("EMERGENCY_SUPPORT_TIME_OVERLAP") ? "이미 등록된 긴급지원 시간과 겹칩니다. 기존 기록을 수정하거나 취소한 뒤 종료해 주세요." : "긴급지원 종료를 기록하지 못했습니다. 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요." });
      return;
    }
    setEmployeeEmergencyWorkOpen(false);
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: `긴급지원 실제시간 ${formatMinutes(Number(minutes) || 0)}을 승인 대기로 저장했습니다.` });
  }

  async function cancelEmergencySupportWork(request: CorrectionRequest) {
    if (!supabase || !currentProfile) return;
    const reason = window.prompt("긴급지원을 취소하는 이유를 입력해 주세요.") || "";
    if (reason.trim().length < 2) return;
    setBusy(true);
    const { error } = await supabase.rpc("employee_cancel_emergency_support_work", { p_request_id: request.id, p_reason: reason });
    setBusy(false);
    if (error) { setNotice({ tone: "error", text: "긴급지원 기록을 취소하지 못했습니다. 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요." }); return; }
    setEmployeeEmergencyWorkOpen(false);
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "긴급지원 기록을 취소했습니다. 취소 사유는 변경 이력에 남습니다." });
  }

  async function reviewRequest(request: CorrectionRequest, decision: "approved" | "rejected" | "more_info") {
    const comment = window.prompt(decision === "approved" ? "승인 의견을 입력해 주세요. 선택 입력입니다." : "처리 의견을 입력해 주세요.") ?? "";
    if (decision !== "approved" && !comment.trim()) return;
    if (supabase) {
      const reviewFunction = request.request_type === "emergency_support" ? "review_emergency_support_work" : "review_correction_request";
      const { error } = await supabase.rpc(reviewFunction, { p_request_id: request.id, p_decision: decision, p_comment: comment });
      if (error) { const message = String(error.message || ""); setNotice({ tone: "error", text: message.includes("EMERGENCY_SUPPORT_TIME_OVERLAP") ? "다른 긴급지원 기록과 시간이 겹쳐 승인할 수 없습니다. 실제시간을 수정하거나 중복 기록을 반려해 주세요." : message.includes("WEEKLY_OVERTIME_LIMIT") ? "이 요청을 승인하면 같은 주의 시간외근무가 12시간을 넘습니다." : message.includes("ACTUAL_OVERTIME_REQUIRED") ? "실제 퇴근기록에서 인정 가능한 시간외근무가 아직 확인되지 않았습니다. 퇴근기록이 저장된 뒤 승인해 주세요." : message.includes("COMP_TIME_BALANCE_INSUFFICIENT") ? "대체휴무 잔액이 부족해 승인할 수 없습니다. 적립내역을 확인하거나 예외 연장 후 다시 승인해 주세요." : message.includes("ANNUAL_LEAVE_BALANCE_INSUFFICIENT") ? "연차 잔액이 부족해 승인할 수 없습니다." : message.includes("ANNUAL_LEAVE_ENTITLEMENT_REQUIRED") ? "해당 기간의 연차 부여내역이 없습니다. 먼저 휴가 잔액 화면에서 연차를 등록해 주세요." : "요청을 처리하지 못했습니다. 권한, 월 마감 상태, 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요." }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    } else {
      setRequests((previous) => previous.map((item) => item.id === request.id ? { ...item, status: decision, reviewer_comment: comment, reviewed_at: new Date().toISOString() } : item));
      setAuditLogs((previous) => [{ id: crypto.randomUUID(), attendance_record_id: request.attendance_record_id, employee_id: request.employee_id, employee_name: request.employee_name, action_type: "correction_review", changed_field: request.request_type, before_value: request.before_value, after_value: request.requested_value, reason: comment || request.reason, changed_by_name: currentProfile?.name, changed_by_role: effectiveRole, created_at: new Date().toISOString() }, ...previous]);
    }
    setNotice({ tone: "success", text: decision === "approved" ? "요청을 승인했습니다." : decision === "rejected" ? "요청을 반려했습니다." : "추가정보를 요청했습니다." });
  }

  async function reopenRequest(request: CorrectionRequest) {
    const reason = window.prompt("이 요청을 다시 검토하는 이유를 입력해 주세요.") || "";
    if (reason.trim().length < 2) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_reopen_correction_request", { p_request_id: request.id, p_reason: reason });
      if (error) { setNotice({ tone: "error", text: `요청을 재검토 상태로 바꾸지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 월 마감 여부와 데이터베이스 보완 SQL을 확인해 주세요.` }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    } else setRequests((previous) => previous.map((item) => item.id === request.id ? { ...item, status: "pending", reviewer_comment: "", reviewed_at: null } : item));
    setNotice({ tone: "success", text: "요청을 검토 대기 상태로 되돌렸습니다. 이전 처리 내용은 변경 이력에 남았습니다." });
  }

  async function updateAttendanceRequest(form: HTMLFormElement) {
    if (!editingRequest || !currentProfile) return;
    const data = new FormData(form);
    const startDate = String(data.get("target_date") || editingRequest.target_date);
    const requestType = isAdminRole(effectiveRole) ? String(data.get("request_type") || editingRequest.request_type) : editingRequest.request_type;
    const isClockRequest = ["clock_in_at", "clock_out_at"].includes(requestType);
    const activeEmergency = requestType === "emergency_support" && !editingRequest.end_time;
    const endDate = activeEmergency ? null : requestType === "overtime" || isClockRequest ? startDate : String(data.get("end_date") || startDate);
    const payload = {
      p_request_id: editingRequest.id,
      p_start_date: startDate,
      p_end_date: endDate,
      p_start_time: isClockRequest ? null : String(data.get("start_time") || "") || null,
      p_end_time: isClockRequest ? null : String(data.get("end_time") || "") || null,
      p_request_subtype: String(data.get("request_subtype") || ""),
      p_requested_value: isClockRequest ? String(data.get("requested_value") || "") : editingRequest.requested_value,
      p_reason: String(data.get("reason") || ""),
    };
    if (payload.p_reason.trim().length < 5) { setNotice({ tone: "warning", text: "수정 사유를 5자 이상 입력해 주세요." }); return; }
    if (requestType === "emergency_support" && payload.p_end_date && payload.p_start_time && payload.p_end_time && overlappingEmergencyRequests(requests, editingRequest.employee_id, payload.p_start_date, payload.p_end_date, payload.p_start_time, payload.p_end_time, editingRequest.id).length > 0) { setNotice({ tone: "warning", text: "수정한 시간이 다른 긴급지원 기록과 겹칩니다. 두 기록의 실제시간을 확인해 주세요." }); return; }
    if (supabase) {
      const requestFunction = requestType === "emergency_support" ? "update_emergency_support_work" : isAdminRole(effectiveRole) ? "admin_update_attendance_request" : "employee_resubmit_attendance_request";
      const rpcPayload = requestType === "emergency_support" ? {
        p_request_id: payload.p_request_id, p_start_date: payload.p_start_date, p_end_date: payload.p_end_date,
        p_start_time: payload.p_start_time, p_end_time: payload.p_end_time, p_reason: payload.p_reason,
      } : isAdminRole(effectiveRole) ? { ...payload, p_request_type: requestType } : payload;
      const { error } = await supabase.rpc(requestFunction, rpcPayload);
      if (error) { const message = String(error.message || ""); setNotice({ tone: "error", text: message.includes("EMERGENCY_SUPPORT_TIME_OVERLAP") ? "수정한 시간이 다른 긴급지원 기록과 겹칩니다. 두 기록의 실제시간을 확인해 주세요." : `요청 내용을 수정하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 월 마감 여부와 데이터베이스 보완 SQL을 확인해 주세요.` }); return; }
      await loadRemoteData(currentProfile);
    } else setRequests((previous) => previous.map((item) => item.id === editingRequest.id ? { ...item, request_type: requestType, target_date: startDate, end_date: endDate, start_time: payload.p_start_time, end_time: payload.p_end_time, request_subtype: payload.p_request_subtype, requested_value: payload.p_requested_value, reason: payload.p_reason, status: "pending", reviewer_comment: "", reviewed_at: null } : item));
    setEditingRequest(null);
    setNotice({ tone: "success", text: requestType === "emergency_support" ? "긴급지원 실제시간을 수정했습니다. 변경 전후 시각은 변경 이력에 남습니다." : isAdminRole(effectiveRole) ? "요청 내용을 수정하고 검토 대기 상태로 변경했습니다. 이전 내용은 변경 이력에 남았습니다." : "신청 내용을 수정해 다시 제출했습니다. 이전 반려 내용과 재제출 내용은 변경 이력에 남았습니다." });
  }

  async function reviewOvertime(record: AttendanceRecord, decision: "approved" | "rejected") {
    const recordedMinutes = record.recorded_overtime_minutes || 0;
    const emergencyMinutes = approvedEmergencyMinutesForRecord(record, requests);
    const regularRecordedMinutes = Math.max(0, recordedMinutes - finishedEmergencyMinutesForRecord(record, requests));
    const rawMinutes = Math.max(0, Math.max(record.raw_overtime_minutes || 0, recordedMinutes) - finishedEmergencyMinutesForRecord(record, requests));
    const overtimeRequest = requests.filter((request) => request.employee_id === record.employee_id && request.target_date === record.work_date && request.request_type === "overtime").sort((a, b) => b.requested_at.localeCompare(a.requested_at))[0];
    const requestedMinutes = overtimeRequest ? overtimeRequest.calculated_minutes || Number(overtimeRequest.requested_value) || recordedMinutes : recordedMinutes;
    const approvalLimit = Math.min(regularRecordedMinutes, requestedMinutes);
    let approvedMinutes = 0;
    let compTimeCreditMinutes = 0;
    if (decision === "approved") {
      if (approvalLimit < 60) { setNotice({ tone: "info", text: emergencyMinutes > 0 ? `긴급지원 ${formatMinutes(emergencyMinutes)}은 별도로 인정되어 일반 시간외근무 승인 대상이 없습니다.` : "일반 시간외근무 승인 대상이 없습니다." }); return; }
      const input = window.prompt(`승인할 일반 시간외근무 시간을 분 단위로 입력해 주세요. 긴급지원 ${formatMinutes(emergencyMinutes)}은 별도로 표시됩니다. 일반 시간외근무 인정 가능 ${formatMinutes(approvalLimit)} 안에서 승인할 수 있습니다.`, String(approvalLimit));
      if (input === null) return;
      approvedMinutes = Number(input);
      if (![60, 90, 120, 150, 180, 210, 240].includes(approvedMinutes) || approvedMinutes > approvalLimit) {
        setNotice({ tone: "warning", text: "시간외근무는 최초 1시간부터 이후 30분 단위로, 하루 최대 4시간까지 승인할 수 있습니다." });
        return;
      }
      const compTimeLimit = rawMinutes < 60 ? 0 : 60 + Math.ceil((rawMinutes - 60) / 30) * 30;
      const compInput = window.prompt(`대체휴무로 인정할 실제 추가근무 시간을 분 단위로 입력해 주세요. 해당 없으면 0을 입력하세요.\n\n시간외근무 승인시간과 별도로 실제 추가근무 전체를 대체휴무로 적립할 수 있습니다. 최초 1시간부터 이후 30분 단위로 인정합니다.\n현재 적립 가능: 최대 ${formatMinutes(compTimeLimit)}\n예: 실제 추가근무 5시간이면 시간외근무는 최대 4시간, 대체휴무는 5시간 적립 가능`, "0");
      if (compInput === null) return;
      compTimeCreditMinutes = Number(compInput);
      if (!Number.isInteger(compTimeCreditMinutes) || compTimeCreditMinutes < 0 || compTimeCreditMinutes > compTimeLimit || (compTimeCreditMinutes > 0 && (compTimeCreditMinutes < 60 || compTimeCreditMinutes % 30 !== 0))) {
        setNotice({ tone: "warning", text: `대체휴무는 실제 추가근무 범위에서 최초 1시간부터 이후 30분 단위로 입력해 주세요. 현재 최대 ${formatMinutes(compTimeLimit)}까지 적립할 수 있습니다.` });
        return;
      }
    }
    const reason = window.prompt(decision === "approved" ? "시간외근무 업무내용과 승인 사유를 입력해 주세요. 이 내용은 출근부 비고란에 표시됩니다." : "반려 사유를 입력해 주세요.") || "";
    if (reason.trim().length < 2) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_review_overtime", { p_record_id: record.id, p_decision: decision, p_approved_minutes: approvedMinutes, p_comp_time_minutes: compTimeCreditMinutes, p_reason: reason });
      if (error) { const message = String(error.message || ""); setNotice({ tone: "error", text: message.includes("WEEKLY_OVERTIME_LIMIT") ? "이 기록을 승인하면 같은 주의 시간외근무가 12시간을 넘습니다." : message.includes("OVERTIME_REQUEST_LIMIT") ? "직원이 신청한 시간보다 많이 승인할 수 없습니다. 신청시간과 실제 인정 가능시간 중 작은 값으로 승인해 주세요." : message.includes("INVALID_EXTRA_COMP_TIME") ? "대체휴무가 실제 추가근무 인정시간을 넘었거나 1시간 이후 30분 단위가 아닙니다." : `시간외근무를 처리하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 최신 데이터베이스 보완 SQL 적용 여부를 확인해 주세요.` }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    } else {
      setRecords((previous) => previous.map((item) => item.id === record.id ? { ...item, overtime_status: decision, approved_overtime_minutes: approvedMinutes } : item));
    }
    setNotice({ tone: "success", text: decision === "approved" ? `시간외근무 ${formatMinutes(approvedMinutes)}을 승인했습니다.${compTimeCreditMinutes > 0 ? ` 실제 추가근무 ${formatMinutes(compTimeCreditMinutes)}은 대체휴무로 적립했으며 30일 동안 사용할 수 있습니다.` : " 대체휴무는 적립하지 않았습니다."}` : "시간외근무를 반려했습니다." });
  }

  async function reopenOvertimeReview(record: AttendanceRecord) {
    if (!supabase) return;
    const reason = window.prompt("시간외근무를 다시 승인 대기 상태로 돌리는 이유를 입력해 주세요.") || "";
    if (reason.trim().length < 2) return;
    const { error } = await supabase.rpc("admin_reopen_overtime_review", { p_record_id: record.id, p_reason: reason });
    if (error) { const message = String(error.message || ""); setNotice({ tone: "error", text: message.includes("COMP_TIME_ALREADY_USED") ? "이미 사용한 대체휴무가 있어 재검토 상태로 되돌릴 수 없습니다. 대체휴무 사용내역을 먼저 확인해 주세요." : `시간외근무를 재검토 상태로 바꾸지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` }); return; }
    if (currentProfile) await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "시간외근무를 승인 대기 상태로 되돌렸습니다. 이제 승인 또는 반려를 다시 선택할 수 있습니다." });
  }

  async function closeMonth() {
    if (monthClosing?.status === "closed") { setNotice({ tone: "info", text: `${formatMonth(selectedMonth)}은 이미 마감됐습니다.` }); return; }
    if (!window.confirm(`${formatMonth(selectedMonth)} 근태를 마감하시겠습니까? 마감 후에는 일반 수정이 제한됩니다.`)) return;
    if (supabase) {
      const { error } = await supabase.rpc("close_attendance_month", { p_year: Number(selectedMonth.slice(0, 4)), p_month: Number(selectedMonth.slice(5, 7)) });
      if (error) { setNotice({ tone: "error", text: "월 마감을 처리하지 못했습니다. 대기 중인 근태 신청이 있는지 확인해 주세요." }); return; }
    }
    setRecords((previous) => previous.map((record) => record.work_date.startsWith(selectedMonth) ? { ...record, is_closed: true } : record));
    setMonthClosing({ year: Number(selectedMonth.slice(0, 4)), month: Number(selectedMonth.slice(5, 7)), status: "closed", closed_at: new Date().toISOString(), reopened_at: null, reopen_reason: "" });
    setNotice({ tone: "success", text: `${formatMonth(selectedMonth)} 근태를 마감했습니다.` });
  }

  async function reopenMonth() {
    if (effectiveRole !== "super_admin") { setNotice({ tone: "warning", text: "월 마감 해제는 최고관리자만 할 수 있습니다." }); return; }
    const reason = window.prompt(`${formatMonth(selectedMonth)} 월 마감을 다시 여는 사유를 입력해 주세요.`) || "";
    if (reason.trim().length < 5) { if (reason) setNotice({ tone: "warning", text: "마감 해제 사유를 5자 이상 입력해 주세요." }); return; }
    if (!window.confirm(`${formatMonth(selectedMonth)}을 다시 열까요? 다시 열면 기록 수정과 요청 승인이 가능해집니다.`)) return;
    if (supabase) {
      const { error } = await supabase.rpc("reopen_attendance_month", { p_year: Number(selectedMonth.slice(0, 4)), p_month: Number(selectedMonth.slice(5, 7)), p_reason: reason });
      if (error) { setNotice({ tone: "error", text: `월 마감을 해제하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 최고관리자 권한을 확인해 주세요.` }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    }
    setRecords((previous) => previous.map((record) => record.work_date.startsWith(selectedMonth) ? { ...record, is_closed: false } : record));
    setMonthClosing((current) => ({ year: current?.year || Number(selectedMonth.slice(0, 4)), month: current?.month || Number(selectedMonth.slice(5, 7)), status: "open", closed_at: current?.closed_at || null, reopened_at: new Date().toISOString(), reopen_reason: reason }));
    setNotice({ tone: "success", text: `${formatMonth(selectedMonth)} 월 마감을 해제했습니다.` });
  }

  async function saveSettings() {
    const organizationResult = await persistOrganizationSettings(organizationSettingsDraft);
    if (!organizationResult.settings) { setNotice({ tone: "error", text: `근무시간 설정을 저장하지 못했습니다. 오류코드 ${organizationResult.errorCode || "확인 불가"}` }); return; }
    setOrganizationSettingsDraft(organizationResult.settings);
    setNotice(organizationResult.featureSqlRequired
      ? { tone: "warning", text: "기존 근무 설정은 저장했지만 긴급지원 설정은 데이터베이스 SQL 적용 후 사용할 수 있습니다." }
      : { tone: "success", text: "근무시간과 기관별 근무조건을 저장했습니다." });
  }

  async function saveWorkPolicy() {
    if (!supabase || !currentProfile?.org_id || !["admin", "org_admin"].includes(effectiveRole)) return;
    if (workPolicyDraft.max_open_shift_hours < 8 || workPolicyDraft.max_open_shift_hours > 48) {
      setNotice({ tone: "warning", text: "연속 근무 허용시간은 8시간에서 48시간 사이로 입력해 주세요." });
      return;
    }
    setBusy(true);
    const next = { ...workPolicyDraft, org_id: currentProfile.org_id, updated_by: currentProfile.id, updated_at: new Date().toISOString() };
    const { data, error } = await supabase.from("organization_work_policies").upsert(next, { onConflict: "org_id" }).select("*").single();
    setBusy(false);
    if (error || !data) {
      const errorCode = error?.code || "WORK_POLICY_SAVE_FAILED";
      setNotice({ tone: "error", text: `근무방식 설정을 저장하지 못했습니다 (${errorCode}). 기관별 근무정책 SQL 적용 여부를 확인해 주세요.` });
      return;
    }
    setWorkPolicyDraft({ ...(data as OrganizationWorkPolicy), work_date_boundary_time: String(data.work_date_boundary_time).slice(0, 5) });
    setNotice({ tone: "success", text: "기관의 근무방식과 야간 근무 기준을 저장했습니다." });
  }

  async function createShiftTemplate(form: HTMLFormElement) {
    if (!supabase || !currentProfile?.org_id || !["admin", "org_admin"].includes(effectiveRole)) return;
    const values = new FormData(form);
    const startTime = String(values.get("start_time") || "");
    const endTime = String(values.get("end_time") || "");
    const crossesMidnight = values.get("crosses_midnight") === "on";
    if (!crossesMidnight && endTime <= startTime) {
      setNotice({ tone: "warning", text: "당일 근무의 종료시각은 시작시각보다 늦어야 합니다." });
      return;
    }
    setBusy(true);
    const { data, error } = await supabase.from("work_shift_templates").insert({
      org_id: currentProfile.org_id,
      shift_code: String(values.get("shift_code") || "").trim().toUpperCase(),
      shift_name: String(values.get("shift_name") || "").trim(),
      start_time: startTime,
      end_time: endTime,
      crosses_midnight: crossesMidnight,
      break_minutes: Number(values.get("break_minutes") || 0),
      late_grace_minutes: Number(values.get("late_grace_minutes") || 0),
      early_leave_grace_minutes: 0,
      created_by: currentProfile.id,
    }).select("*").single();
    setBusy(false);
    if (error || !data) {
      setNotice({ tone: "error", text: "근무조를 만들지 못했습니다. 같은 코드가 이미 있는지 확인해 주세요." });
      return;
    }
    form.reset();
    setShiftTemplates((current) => [...current, { ...data, start_time: String(data.start_time).slice(0, 5), end_time: String(data.end_time).slice(0, 5) } as WorkShiftTemplate].sort((a, b) => a.shift_name.localeCompare(b.shift_name, "ko")));
    setNotice({ tone: "success", text: `${data.shift_name} 근무조를 만들었습니다.` });
  }

  async function setShiftTemplateActive(template: WorkShiftTemplate, active: boolean) {
    if (!supabase || !["admin", "org_admin"].includes(effectiveRole)) return;
    setBusy(true);
    const { error } = await supabase.from("work_shift_templates").update({ is_active: active, updated_at: new Date().toISOString() }).eq("id", template.id);
    setBusy(false);
    if (error) { setNotice({ tone: "error", text: "근무조 상태를 바꾸지 못했습니다." }); return; }
    setShiftTemplates((current) => current.map((item) => item.id === template.id ? { ...item, is_active: active } : item));
  }

  async function assignEmployeeShift(form: HTMLFormElement) {
    if (!supabase || !currentProfile?.org_id || !["admin", "org_admin"].includes(effectiveRole)) return;
    const values = new FormData(form);
    const employeeId = String(values.get("employee_id") || "");
    const workDate = String(values.get("work_date") || "");
    const shiftTemplateId = String(values.get("shift_template_id") || "");
    setBusy(true);
    const { data, error } = await supabase.from("employee_shift_assignments").upsert({
      org_id: currentProfile.org_id,
      employee_id: employeeId,
      work_date: workDate,
      shift_template_id: shiftTemplateId,
      note: String(values.get("note") || "").trim(),
      created_by: currentProfile.id,
    }, { onConflict: "employee_id,work_date" }).select("*").single();
    setBusy(false);
    if (error || !data) { setNotice({ tone: "error", text: "직원 근무조를 배정하지 못했습니다." }); return; }
    setShiftAssignments((current) => [...current.filter((item) => !(item.employee_id === employeeId && item.work_date === workDate)), data as EmployeeShiftAssignment].sort((a, b) => a.work_date.localeCompare(b.work_date)));
    setNotice({ tone: "success", text: "직원 근무조를 배정했습니다." });
  }

  async function removeShiftAssignment(assignment: EmployeeShiftAssignment) {
    if (!supabase || !["admin", "org_admin"].includes(effectiveRole)) return;
    setBusy(true);
    const { error } = await supabase.from("employee_shift_assignments").delete().eq("id", assignment.id);
    setBusy(false);
    if (error) { setNotice({ tone: "error", text: "근무조 배정을 취소하지 못했습니다." }); return; }
    setShiftAssignments((current) => current.filter((item) => item.id !== assignment.id));
  }

  async function persistOrganizationSettings(next: OrganizationSettings): Promise<{ settings: OrganizationSettings | null; errorCode: string | null; featureSqlRequired?: boolean }> {
    if (!supabase) return { settings: next, errorCode: null };
    const { data, error } = await supabase.rpc("save_organization_settings", {
      p_default_start_time: next.default_start_time,
      p_default_end_time: next.default_end_time,
      p_break_minutes: next.break_minutes,
      p_late_grace_minutes: next.late_grace_minutes,
      p_early_leave_grace_minutes: next.early_leave_grace_minutes,
      p_office_ip_address: next.office_ip_address.trim(),
      p_emergency_support_enabled: next.emergency_support_enabled,
    });
    if (error && error.code === "PGRST202") {
      const legacyResult = await supabase.rpc("save_organization_settings", {
        p_default_start_time: next.default_start_time,
        p_default_end_time: next.default_end_time,
        p_break_minutes: next.break_minutes,
        p_late_grace_minutes: next.late_grace_minutes,
        p_early_leave_grace_minutes: next.early_leave_grace_minutes,
        p_office_ip_address: next.office_ip_address.trim(),
      });
      if (legacyResult.error) return { settings: null, errorCode: legacyResult.error.code || "RPC_ERROR" };
      const legacySaved = (Array.isArray(legacyResult.data) ? legacyResult.data[0] : legacyResult.data) as OrganizationSettings | null;
      return { settings: normalizeOrganizationSettings(legacySaved || { ...next, emergency_support_enabled: true }), errorCode: null, featureSqlRequired: true };
    }
    if (error) return { settings: null, errorCode: error.code || "RPC_ERROR" };
    const saved = (Array.isArray(data) ? data[0] : data) as OrganizationSettings | null;
    return { settings: normalizeOrganizationSettings(saved || next), errorCode: null };
  }

  async function loadHolidays(year: number) {
    if (!supabase) return;
    const { data, error } = await supabase.from("organization_holidays").select("org_id,holiday_date,holiday_name,is_paid_holiday").gte("holiday_date", `${year}-01-01`).lte("holiday_date", `${year}-12-31`).order("holiday_date");
    if (!error) setHolidays((data || []) as Holiday[]);
  }

  async function toggleReportViewer(person: Profile) {
    if (!supabase || !currentProfile || !isAdminRole(currentProfile.role)) return;
    const enabled = !person.can_view_reports;
    const action = enabled ? "부관리자로 지정" : "부관리자 권한을 해제";
    if (!window.confirm(`${person.name}님을 ${action}할까요?\n\n부관리자는 전체 직원의 월별 근태현황을 보고 엑셀을 내려받을 수 있지만, 승인, 수정, 삭제, 설정은 할 수 없습니다.`)) return;
    const { error } = await supabase.rpc("admin_set_report_viewer", { p_employee_id: person.id, p_enabled: enabled });
    if (error) { setNotice({ tone: "error", text: `부관리자 권한을 변경하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 데이터베이스 보완 SQL을 적용해 주세요.` }); return; }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: `${person.name}님의 ${enabled ? "부관리자 권한을 설정" : "부관리자 권한을 해제"}했습니다.` });
  }

  async function syncHolidays() {
    if (!supabase || !currentProfile || !isAdminRole(currentProfile.role)) return;
    const year = holidayYear;
    setBusy(true);
    try {
      const response = await fetch(`/api/korean-holidays?year=${year}`, { cache: "no-store" });
      const result = await response.json() as { holidays?: Array<{ holiday_date: string; holiday_name: string; is_paid_holiday: boolean }> };
      if (!response.ok || !result.holidays?.length) { setNotice({ tone: "error", text: `${year}년 공휴일을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.` }); return; }
      const preview = result.holidays.map((holiday) => `${holiday.holiday_date} ${holiday.holiday_name}`).join("\n");
      if (!window.confirm(`${year}년 공휴일 ${result.holidays.length}건을 현재 목록에 보완할까요?\n\n${preview}\n\n이미 저장된 날짜는 최신 이름으로 갱신되고, 기관이 직접 추가한 다른 날짜는 유지됩니다.`)) return;
      const orgId = currentProfile?.org_id;
      if (!orgId) throw new Error("ORGANIZATION_REQUIRED");
      const { error } = await supabase.from("organization_holidays").upsert(result.holidays.map((holiday) => ({ ...holiday, org_id: orgId, created_by: currentProfile.id })), { onConflict: "org_id,holiday_date" });
      if (error) { setNotice({ tone: "error", text: `공휴일을 저장하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 관리자 권한을 확인해 주세요.` }); return; }
      await loadHolidays(year);
      setNotice({ tone: "success", text: `${year}년 공휴일 ${result.holidays.length}건으로 목록을 보완했습니다.` });
    } finally { setBusy(false); }
  }

  async function addCustomHoliday() {
    if (!supabase || !currentProfile || !isAdminRole(currentProfile.role)) return;
    const date = window.prompt("기관 휴일 날짜를 YYYY-MM-DD 형식으로 입력해 주세요.") || "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return;
    const name = window.prompt("기관 휴일 이름을 입력해 주세요. 예: 기관 지정 휴일") || "";
    if (name.trim().length < 2) return;
    const { error } = await supabase.from("organization_holidays").upsert({ org_id: currentProfile?.org_id, holiday_date: date, holiday_name: name.trim(), is_paid_holiday: true, created_by: currentProfile?.id }, { onConflict: "org_id,holiday_date" });
    if (!error) { const year = Number(date.slice(0, 4)); setHolidayYear(year); await loadHolidays(year); }
    setNotice(error ? { tone: "error", text: `기관 휴일을 저장하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` } : { tone: "success", text: `${date} ${name.trim()}을 기관 휴일로 저장했습니다.` });
  }

  async function removeHoliday(holiday: Holiday) {
    if (!supabase || !currentProfile || !isAdminRole(currentProfile.role)) return;
    if (!window.confirm(`${holiday.holiday_date} ${holiday.holiday_name}을 휴일 목록에서 취소할까요?\n\n취소한 날짜는 근무일로 다시 계산됩니다.`)) return;
    const { error } = await supabase.from("organization_holidays").delete().eq("org_id", currentProfile?.org_id || "").eq("holiday_date", holiday.holiday_date);
    if (!error) await loadHolidays(holidayYear);
    setNotice(error ? { tone: "error", text: `휴일을 취소하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` } : { tone: "success", text: `${holiday.holiday_date} 휴일 지정을 취소했습니다.` });
  }

  async function editHoliday(holiday: Holiday) {
    if (!supabase || !currentProfile || !isAdminRole(currentProfile.role)) return;
    const nextDate = window.prompt("휴일 날짜를 YYYY-MM-DD 형식으로 수정해 주세요.", holiday.holiday_date) || "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(nextDate)) return;
    const nextName = window.prompt("휴일 이름을 수정해 주세요.", holiday.holiday_name) || "";
    if (nextName.trim().length < 2) return;
    const { error: saveError } = await supabase.from("organization_holidays").upsert({ org_id: currentProfile?.org_id, holiday_date: nextDate, holiday_name: nextName.trim(), is_paid_holiday: true, created_by: currentProfile?.id }, { onConflict: "org_id,holiday_date" });
    if (saveError) { setNotice({ tone: "error", text: `휴일을 수정하지 못했습니다${saveError.code ? ` (오류코드 ${saveError.code})` : ""}.` }); return; }
    if (nextDate !== holiday.holiday_date) {
      const { error: removeOldError } = await supabase.from("organization_holidays").delete().eq("org_id", currentProfile?.org_id || "").eq("holiday_date", holiday.holiday_date);
      if (removeOldError) { setNotice({ tone: "warning", text: "새 날짜는 저장했지만 이전 날짜를 지우지 못했습니다. 목록에서 이전 날짜를 직접 취소해 주세요." }); return; }
    }
    const year = Number(nextDate.slice(0, 4)); setHolidayYear(year); await loadHolidays(year);
    setNotice({ tone: "success", text: `${nextDate} ${nextName.trim()}으로 휴일을 수정했습니다.` });
  }

  async function updateAttendanceRecord(form: HTMLFormElement) {
    if (!editingRecord || !currentProfile) return;
    const data = new FormData(form);
    const payload = {
      p_record_id: editingRecord.id,
      p_clock_in_time: String(data.get("clock_in_time") || "") || null,
      p_clock_out_time: String(data.get("clock_out_time") || "") || null,
      p_work_type: editingRecord.work_type,
      p_attendance_status: editingRecord.attendance_status,
      p_note: attendanceNoteWithoutEmergency(editingRecord.note),
      p_reason: String(data.get("reason") || ""),
    };
    if (payload.p_reason.trim().length < 5) { setNotice({ tone: "warning", text: "수정 사유를 5자 이상 입력해 주세요." }); return; }
    const overtime = calculateEditedOvertime(payload.p_clock_in_time || "", payload.p_clock_out_time || "");
    if (overtime.raw > 240 && !window.confirm(`실제 8시간 근무를 초과한 시간이 ${formatMinutes(overtime.raw)}입니다. 하루 인정 한도는 4시간이므로 최대 4시간까지만 승인할 수 있습니다. 그래도 수정할까요?`)) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_update_attendance", payload);
      if (error) {
        const message = String(error.message || "");
        const reason = message.includes("MONTH_CLOSED") ? "해당 월이 아직 마감 상태입니다."
          : message.includes("INVALID_TIME_RANGE") ? "출근시각과 퇴근시각이 같아 저장할 수 없습니다."
            : message.includes("CLOCK_IN_REQUIRED") ? "퇴근시각을 저장하려면 출근시각이 필요합니다."
              : message.includes("INVALID_WORK_TYPE") ? "과거 근무유형이 현재 설정과 맞지 않습니다. 최신 보완 SQL을 적용해 주세요."
                : message.includes("INVALID_STATUS") ? "과거 근태상태가 현재 허용값과 맞지 않습니다. 최신 보완 SQL을 적용해 주세요."
                  : message || "입력값을 확인해 주세요.";
        setNotice({ tone: "error", text: `근태 값을 수정하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. ${reason}` });
        return;
      }
      await loadRemoteData(currentProfile);
    } else {
      setRecords((current) => current.map((record) => record.id === editingRecord.id ? { ...record, changed: true } : record));
    }
    setEditingRecord(null);
    setNotice({ tone: overtime.raw > 0 ? "warning" : "success", text: overtime.raw > 0 ? `출퇴근 시각을 수정했습니다. 시간외 ${formatMinutes(overtime.raw)}이 기록되었고, 승인 가능 시간은 ${formatMinutes(overtime.recognized)}입니다.` : "출퇴근 시각을 실제 기록에 수정했습니다." });
  }

  async function deleteAttendanceRecord(record: AttendanceRecord) {
    const reason = window.prompt(`${record.employee_name}님의 ${record.work_date} 기록을 삭제 처리하는 사유를 입력해 주세요.`) || "";
    if (reason.trim().length < 5) { if (reason) setNotice({ tone: "warning", text: "삭제 사유를 5자 이상 입력해 주세요." }); return; }
    if (!window.confirm("이 기록을 목록에서 삭제할까요? 삭제 내용과 사유는 변경 이력에 보존됩니다.")) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_delete_attendance", { p_record_id: record.id, p_reason: reason });
      if (error) {
        const detail = error.message.includes("MONTH_CLOSED") ? "월 마감된 기록입니다. 마감을 해제한 뒤 다시 시도해 주세요."
          : error.message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관의 기록은 삭제할 수 없습니다."
            : error.message.includes("ADMIN_REQUIRED") ? "기관관리자 권한을 확인해 주세요."
              : "근태기록 삭제 권한 보완 SQL 적용 여부를 확인해 주세요.";
        setNotice({ tone: "error", text: `기록을 삭제하지 못했습니다. ${detail}` }); return;
      }
      if (currentProfile) await loadRemoteData(currentProfile);
    } else setRecords((current) => current.filter((item) => item.id !== record.id));
    setNotice({ tone: "success", text: "기록을 목록에서 삭제했습니다. 삭제 사유는 변경 이력에 보존됩니다." });
  }

  async function restoreAttendanceRecord(log: AuditLog) {
    if (!log.attendance_record_id) return;
    const reason = window.prompt(`${log.employee_name || "직원"}님의 삭제된 근태기록을 복원하는 사유를 입력해 주세요.`) || "";
    if (reason.trim().length < 5) { if (reason) setNotice({ tone: "warning", text: "복원 사유를 5자 이상 입력해 주세요." }); return; }
    if (!window.confirm("삭제를 취소하고 이 근태기록을 다시 월별 현황에 표시할까요?")) return;
    if (supabase) {
      const { error } = await supabase.rpc("admin_restore_attendance", { p_record_id: log.attendance_record_id, p_reason: reason });
      if (error) { const message = String(error.message || ""); const detail = message.includes("ACTIVE_RECORD_ALREADY_EXISTS") ? "같은 직원과 날짜의 다른 근태기록이 이미 있습니다." : message.includes("MONTH_CLOSED") ? "월 마감된 기록입니다. 마감을 해제한 뒤 다시 시도해 주세요." : message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관의 기록은 복원할 수 없습니다." : message.includes("ADMIN_REQUIRED") ? "기관관리자 권한 보완 SQL을 적용해 주세요." : "근태기록 복원 보완 SQL 적용 여부를 확인해 주세요."; setNotice({ tone: "error", text: `근태기록을 복원하지 못했습니다. ${detail}` }); return; }
      if (currentProfile) await loadRemoteData(currentProfile);
    }
    setNotice({ tone: "success", text: "삭제를 취소하고 근태기록을 복원했습니다. 복원 이력도 변경 이력에 남았습니다." });
  }

  async function createAttendanceException(form: HTMLFormElement) {
    if (!currentProfile || !supabase) return;
    const data = new FormData(form);
    const employeeIds = data.getAll("employee_id").map(String).filter(Boolean);
    const payload = {
      p_employee_ids: employeeIds,
      p_start_date: String(data.get("start_date")),
      p_end_date: String(data.get("end_date")),
      p_exception_type: String(data.get("exception_type")),
      p_reason: String(data.get("reason") || ""),
    };
    if (employeeIds.length === 0 || !payload.p_start_date || !payload.p_end_date) { setNotice({ tone: "warning", text: "직원을 한 명 이상 선택하고 적용 기간을 모두 입력해 주세요." }); return; }
    const { data: result, error } = await supabase.rpc("admin_create_attendance_exceptions", payload);
    if (error) {
      const text = `${error.message || ""} ${error.details || ""}`;
      setNotice({ tone: "error", text: text.includes("EXCEPTION_OVERLAP") ? "해당 직원에게 같은 기간과 겹치는 예외 근무가 이미 있습니다." : text.includes("INVALID_DATE_RANGE") ? "종료일은 시작일보다 빠를 수 없습니다." : text.includes("ORGANIZATION_ACCESS_DENIED") ? "현재 기관에 속하지 않은 직원이 포함되어 있습니다." : text.includes("ADMIN_REQUIRED") ? "기관관리자 권한 보완 SQL을 적용해 주세요." : `예외 근무를 등록하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}. 데이터베이스 보완 SQL 적용 여부를 확인해 주세요.` });
      return;
    }
    await loadRemoteData(currentProfile);
    setExceptionOpen(false);
    const summary = (result || {}) as { created_count?: number; skipped_names?: string[] };
    setNotice({ tone: "success", text: payload.p_exception_type === "external_training" ? `${summary.created_count ?? employeeIds.length}건의 외부교육을 오전 9시 출근, 오후 6시 퇴근 기록으로 만들었습니다.${summary.skipped_names?.length ? ` 기존 기록이 있어 제외: ${summary.skipped_names.join(", ")}` : ""} 출근부 비고에는 교육내용을 표시하지 않습니다.` : `${summary.created_count ?? employeeIds.length}명의 예외 일정을 등록했습니다.${summary.skipped_names?.length ? ` 겹치는 일정이 있어 제외된 직원: ${summary.skipped_names.join(", ")}` : ""} 종일 휴가는 월별 현황과 출근부에도 자동 반영됩니다.` });
  }

  async function saveAnnualLeaveEntitlement(form: HTMLFormElement) {
    if (!supabase || !currentProfile) return;
    const data = new FormData(form);
    const toMinutes = (name: string) => Math.round(Number(data.get(name) || 0) * 480);
    const { error } = await supabase.rpc("admin_save_annual_leave_entitlement", {
      p_entitlement_id: String(data.get("entitlement_id") || "") || null,
      p_employee_id: String(data.get("employee_id")),
      p_valid_from: String(data.get("valid_from")),
      p_valid_to: String(data.get("valid_until")),
      p_base_minutes: toMinutes("granted_days"),
      p_carryover_minutes: toMinutes("carryover_days"),
      p_adjustment_minutes: toMinutes("adjustment_days"),
      p_reason: String(data.get("note") || ""),
    });
    if (error) {
      const message = String(error.message || "");
      const text = message.includes("ANNUAL_LEAVE_PERIOD_OVERLAP") ? "이 직원에게 같은 기간과 겹치는 연차 부여내역이 있습니다. 기존 내역을 수정하거나 기간을 바꿔 주세요."
        : message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관 직원의 연차는 변경할 수 없습니다."
          : message.includes("INVALID_LEAVE_MINUTES") ? "연차 일수는 0.125일 단위로 입력하고 총량이 0일 이상이어야 합니다."
            : `연차 부여내역을 저장하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.`;
      setNotice({ tone: "error", text }); return;
    }
    form.reset();
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "연차 부여기간과 수량을 저장했습니다." });
  }

  async function deleteAnnualLeaveEntitlement(entitlement: AnnualLeaveBalance) {
    if (!supabase || !currentProfile) return;
    const reason = window.prompt(`${profiles.find((person) => person.id === entitlement.employee_id)?.name || "직원"}님의 ${entitlement.valid_from}부터 ${entitlement.valid_to}까지 연차 부여내역을 삭제하는 사유를 5자 이상 입력해 주세요.`) || "";
    if (reason.trim().length < 5) return;
    if (!window.confirm("연차 부여내역을 삭제 처리할까요? 기존 휴가 신청과 변경이력은 보존됩니다.")) return;
    const { error } = await supabase.rpc("admin_delete_annual_leave_entitlement", { p_entitlement_id: entitlement.entitlement_id, p_reason: reason });
    if (error) { setNotice({ tone: "error", text: `연차 부여내역을 삭제하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` }); return; }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "연차 부여내역을 삭제 처리했고 사유를 변경이력에 남겼습니다." });
  }

  async function saveCompTimeCredit(form: HTMLFormElement) {
    if (!supabase || !currentProfile) return;
    const data = new FormData(form);
    const creditId = String(data.get("credit_id") || "");
    const employeeId = data.getAll("employee_id").map(String).find(Boolean) || "";
    const params = {
      p_minutes: Math.round(Number(data.get("hours") || 0) * 60),
      p_source_date: String(data.get("source_date")),
      p_expires_on: String(data.get("expires_on")),
      p_reason: String(data.get("note") || ""),
    };
    const { error } = creditId
      ? await supabase.rpc("admin_update_comp_time_credit", { p_credit_id: creditId, ...params })
      : await supabase.rpc("admin_add_comp_time_credit", { p_employee_id: employeeId, p_source_type: "opening_balance", ...params });
    if (error) {
      const message = String(error.message || "");
      const text = message.includes("MINUTES_BELOW_USED") ? "이미 사용한 시간보다 적은 적립 시간으로는 수정할 수 없습니다."
        : message.includes("AUTOMATIC_CREDIT_READ_ONLY") ? "시간외근무 승인으로 자동 적립된 내역은 수정할 수 없습니다."
          : `대체휴무 적립내역을 저장하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.`;
      setNotice({ tone: "error", text }); return;
    }
    form.reset();
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: creditId ? "대체휴무 적립내역을 수정했습니다." : "대체휴무 시작 잔액을 저장했습니다." });
  }

  async function deleteCompTimeCredit(credit: CompTimeCredit) {
    if (!supabase || !currentProfile) return;
    const reason = window.prompt("대체휴무 적립내역을 삭제하는 사유를 5자 이상 입력해 주세요.") || "";
    if (reason.trim().length < 5) return;
    if (!window.confirm("이 적립내역을 삭제할까요? 변경이력은 남습니다.")) return;
    const { error } = await supabase.rpc("admin_delete_comp_time_credit", { p_credit_id: credit.id, p_reason: reason });
    if (error) {
      const message = String(error.message || "");
      setNotice({ tone: "error", text: message.includes("USED_CREDIT_CANNOT_DELETE") ? "이미 사용된 내역은 삭제할 수 없습니다. 잔액과 사용 기록을 보존해야 합니다." : `대체휴무 적립내역을 삭제하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` });
      return;
    }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "대체휴무 적립내역을 삭제했고 사유를 변경이력에 남겼습니다." });
  }

  async function extendCompTimeCredit(credit: CompTimeCredit) {
    if (!supabase || !currentProfile) return;
    const expiresOn = window.prompt("변경할 사용기한을 입력해 주세요. 늘리거나 이전 날짜로 되돌릴 수 있습니다.", credit.expires_on) || "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(expiresOn) || expiresOn < credit.source_date || expiresOn === credit.expires_on) { if (expiresOn) setNotice({ tone: "warning", text: expiresOn === credit.expires_on ? "현재 사용기한과 같습니다." : "발생일 이후의 올바른 날짜를 입력해 주세요." }); return; }
    const reason = window.prompt("사용기한을 변경하는 사유를 5자 이상 입력해 주세요.") || "";
    if (reason.trim().length < 5) return;
    const { error } = await supabase.rpc("admin_extend_comp_time_credit", { p_credit_id: credit.id, p_new_expires_on: expiresOn, p_reason: reason });
    if (error) { setNotice({ tone: "error", text: `대체휴무 사용기한을 변경하지 못했습니다${error.code ? ` (오류코드 ${error.code})` : ""}.` }); return; }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "대체휴무 사용기한을 변경했고 이전 날짜와 사유를 변경이력에 남겼습니다." });
  }

  async function cancelAttendanceException(item: AttendanceException) {
    if (!currentProfile || !supabase) return;
    const reason = window.prompt(`${item.employee_name}님의 ${item.start_date}부터 ${item.end_date}까지 예외 근무를 취소하는 사유를 입력해 주세요.`) || "";
    if (reason.trim().length < 5) { if (reason) setNotice({ tone: "warning", text: "취소 사유를 5자 이상 입력해 주세요." }); return; }
    const { error } = await supabase.rpc("admin_cancel_attendance_exception", { p_exception_id: item.id, p_reason: reason });
    if (error) { const message = String(error.message || ""); const detail = message.includes("ORGANIZATION_ACCESS_DENIED") ? "다른 기관의 예외 근무는 취소할 수 없습니다." : message.includes("ADMIN_REQUIRED") ? "기관관리자 권한 보완 SQL을 적용해 주세요." : message.includes("EXCEPTION_NOT_FOUND") ? "이미 취소됐거나 찾을 수 없는 일정입니다." : `데이터베이스 오류코드 ${error.code || "확인 불가"}`; setNotice({ tone: "error", text: `예외 근무를 취소하지 못했습니다. ${detail}` }); return; }
    await loadRemoteData(currentProfile);
    setNotice({ tone: "success", text: "예외 근무를 취소했습니다. 취소 사유는 변경 이력에 보존됩니다." });
  }

  function includeExceptionDays(sourceRows: AttendanceRecord[]) {
    const rows = [...sourceRows];
    const keys = new Set(rows.map((row) => `${row.employee_id}:${row.work_date}`));
    const monthStart = `${selectedMonth}-01`;
    const next = new Date(`${monthStart}T12:00:00+09:00`); next.setMonth(next.getMonth() + 1);
    const monthEnd = KST_DATE.format(next);
    exceptions.filter((item) => ["business_trip", "external_training"].includes(item.exception_type) && !item.cancelled_at && item.start_date < monthEnd && item.end_date >= monthStart).forEach((item) => {
      const date = new Date(`${item.start_date < monthStart ? monthStart : item.start_date}T12:00:00+09:00`);
      const end = item.end_date >= monthEnd ? monthEnd : KST_DATE.format(new Date(new Date(`${item.end_date}T12:00:00+09:00`).getTime() + 86_400_000));
      while (KST_DATE.format(date) < end) {
        const workDate = KST_DATE.format(date); const key = `${item.employee_id}:${workDate}`;
        if (!keys.has(key)) {
          const isTrip = item.exception_type === "business_trip";
          rows.push({ id: `exception-${item.id}-${workDate}`, employee_id: item.employee_id, employee_name: item.employee_name || profiles.find((profile) => profile.id === item.employee_id)?.name, work_date: workDate, work_type: isTrip ? "business_trip" : "approved_other", clock_in_at: null, clock_out_at: null, clock_in_accuracy: null, clock_in_distance: null, clock_in_location_status: "not_checked", clock_out_accuracy: null, clock_out_distance: null, clock_out_location_status: "not_checked", attendance_status: isTrip ? "business_trip" : "education", note: `${isTrip ? "출장" : "외부교육"}${item.reason ? `: ${item.reason}` : ""}`, is_closed: false });
          keys.add(key);
        }
        date.setDate(date.getDate() + 1);
      }
    });
    requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.target_date >= monthStart && request.target_date < monthEnd).forEach((request) => {
      const key = `${request.employee_id}:${request.target_date}`;
      if (keys.has(key)) return;
      rows.push({ id: `emergency-${request.id}-${request.target_date}`, employee_id: request.employee_id, employee_name: request.employee_name || profiles.find((profile) => profile.id === request.employee_id)?.name, work_date: request.target_date, work_type: "approved_other", clock_in_at: null, clock_out_at: null, clock_in_accuracy: null, clock_in_distance: null, clock_in_location_status: "not_checked", clock_out_accuracy: null, clock_out_distance: null, clock_out_location_status: "not_checked", attendance_status: "holiday_work", note: "", is_closed: false });
      keys.add(key);
    });
    return rows.sort((a, b) => a.work_date.localeCompare(b.work_date) || (a.employee_name || "").localeCompare(b.employee_name || ""));
  }

  function exportCsv(rows: AttendanceRecord[]) {
    rows = includeExceptionDays(rows);
    const headers = ["직원명", "날짜", "출근시간", "퇴근시간", "출근", "일반 시간외근무", "긴급지원 인정시간", "시간외근무 합계", "대휴", "휴가", "출장", "병가", "비고"];
    const values = rows.map((row) => {
      const dayRequests = requests.filter((request) => request.employee_id === row.employee_id && request.target_date === row.work_date && request.status === "approved");
      const annual = dayRequests.find((request) => request.request_type === "annual_leave");
      const specialLeave = dayRequests.find((request) => request.request_type === "special_leave");
      const otherLeave = dayRequests.find((request) => request.request_type === "other_leave");
      const comp = dayRequests.find((request) => request.request_type === "comp_time");
      const leave = annual ? leaveUnitLabel(Number(annual.requested_value)) : specialLeave ? `${specialLeave.request_subtype || "특별휴가"} ${requestValueLabel(specialLeave)}` : otherLeave ? `${otherLeave.request_subtype || "기타 휴가"} ${requestValueLabel(otherLeave)}` : "";
      const emergencyMinutes = approvedEmergencyMinutesForRecord(row, requests);
      return [row.employee_name || "", row.work_date, formatTime(row.clock_in_at), formatTime(effectiveClockOutAt(row, requests)), row.clock_in_at ? "1" : "", formatMinutes(regularApprovedOvertimeMinutes(row, requests)), formatMinutes(emergencyMinutes), formatMinutes(totalApprovedOvertimeMinutes(row, requests)), comp ? formatMinutes(Number(comp.requested_value)) : "", leave, row.work_type === "business_trip" || row.attendance_status === "business_trip" ? "1일" : "", row.leave_type === "sick_leave" ? "1일" : "", [attendanceNoteWithoutEmergency(row.note), emergencySupportRemark(row, requests)].filter(Boolean).join("\n")];
    });
    const csv = [headers, ...values].map((line) => line.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(",")).join("\r\n");
    downloadBlob(new Blob(["\uFEFF" + csv], { type: "text/csv;charset=utf-8" }), `${selectedMonth}_월간근태기록.csv`);
  }

  async function exportExcel(rows: AttendanceRecord[]) {
    rows = includeExceptionDays(rows);
    const exportMonthStart = `${selectedMonth}-01`;
    const exportNextMonth = new Date(`${exportMonthStart}T12:00:00+09:00`); exportNextMonth.setMonth(exportNextMonth.getMonth() + 1);
    const exportMonthEnd = KST_DATE.format(exportNextMonth);
    let exportHolidays = holidays.filter((holiday) => holiday.holiday_date >= exportMonthStart && holiday.holiday_date < exportMonthEnd);
    const compTimeSources = new Map<string, string[]>();
    if (supabase) {
      const { data } = await supabase.from("organization_holidays").select("org_id,holiday_date,holiday_name,is_paid_holiday").gte("holiday_date", exportMonthStart).lt("holiday_date", exportMonthEnd).order("holiday_date");
      if (data) exportHolidays = data as Holiday[];
      const compRequestIds = requests.filter((request) => request.status === "approved" && request.request_type === "comp_time" && request.target_date < exportMonthEnd && (request.end_date || request.target_date) >= exportMonthStart).map((request) => request.id);
      if (compRequestIds.length > 0) {
        const { data: allocationData } = await supabase.from("comp_time_usage_allocations").select("correction_request_id,credit_id,used_minutes").in("correction_request_id", compRequestIds);
        const allocations = (allocationData || []) as Array<{ correction_request_id: string; credit_id: string; used_minutes: number }>;
        const creditIds = [...new Set(allocations.map((item) => item.credit_id))];
        if (creditIds.length > 0) {
          const { data: creditData } = await supabase.from("comp_time_credits").select("id,attendance_record_id").in("id", creditIds);
          const credits = (creditData || []) as Array<{ id: string; attendance_record_id: string }>;
          const sourceRecordIds = [...new Set(credits.map((item) => item.attendance_record_id))];
          const { data: sourceRecordData } = sourceRecordIds.length > 0 ? await supabase.from("attendance_records_view").select("id,work_date").in("id", sourceRecordIds) : { data: [] };
          const sourceDates = new Map(((sourceRecordData || []) as Array<{ id: string; work_date: string }>).map((item) => [item.id, item.work_date]));
          const creditRecords = new Map(credits.map((item) => [item.id, sourceDates.get(item.attendance_record_id) || "발생일 미확인"]));
          allocations.forEach((item) => {
            const current = compTimeSources.get(item.correction_request_id) || [];
            current.push(`${creditRecords.get(item.credit_id) || "발생일 미확인"} 시간외근무 ${formatMinutes(item.used_minutes)}`);
            compTimeSources.set(item.correction_request_id, current);
          });
        }
      }
    }
    const holidayMap = new Map(exportHolidays.map((holiday) => [holiday.holiday_date, holiday.holiday_name]));
    const ExcelJS = await import("exceljs");
    const workbook = new ExcelJS.Workbook();
    workbook.creator = tenantBranding.title;
    const logSheet = workbook.addWorksheet("전체 출퇴근 로그", { views: [{ state: "frozen", ySplit: 1 }] });
    const logHeaders = ["직원명", "날짜", "출근시각", "출근장소", "출근 GPS 정확도", "출근 거리", "출근 IP", "퇴근시각", "퇴근장소", "퇴근 GPS 정확도", "퇴근 거리", "퇴근 IP", "근태상태", "수정 여부", "비고"];
    logSheet.addRow(logHeaders);
    rows.forEach((record) => logSheet.addRow([
      record.employee_name || "", record.work_date, record.clock_in_at ? formatTime(record.clock_in_at) : "", attendancePlaceLabel("clock_in", record.clock_in_location_status, record.clock_in_ip_matched),
      record.clock_in_accuracy == null ? "" : `${record.clock_in_accuracy}m`, record.clock_in_distance == null ? "" : `${record.clock_in_distance}m`, record.clock_in_ip_address || "",
      effectiveClockOutAt(record, requests) ? formatTime(effectiveClockOutAt(record, requests)) : "", attendancePlaceLabel("clock_out", record.clock_out_location_status, record.clock_out_ip_matched),
      record.clock_out_accuracy == null ? "" : `${record.clock_out_accuracy}m`, record.clock_out_distance == null ? "" : `${record.clock_out_distance}m`, record.clock_out_ip_address || "",
      STATUS_LABEL[record.attendance_status], record.changed ? "수정됨" : "최초 기록", attendanceNoteWithoutEmergency(record.note),
    ]));
    logSheet.columns = [{ width: 12 }, { width: 13 }, { width: 11 }, { width: 24 }, { width: 16 }, { width: 12 }, { width: 18 }, { width: 11 }, { width: 24 }, { width: 16 }, { width: 12 }, { width: 18 }, { width: 18 }, { width: 12 }, { width: 28 }];
    logSheet.autoFilter = { from: "A1", to: "O1" };
    logSheet.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
    logSheet.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF173F35" } };
    logSheet.eachRow((row) => { row.alignment = { vertical: "middle", wrapText: true }; row.eachCell((cell) => { cell.border = { bottom: { style: "thin", color: { argb: "FFD5DBD7" } } }; }); });

    const recordIds = new Set(rows.filter((record) => !record.id.startsWith("exception-")).map((record) => record.id));
    const monthAuditLogs = auditLogs.filter((log) => log.target_work_date?.startsWith(selectedMonth) || Boolean(log.attendance_record_id && recordIds.has(log.attendance_record_id)));
    const historySheet = workbook.addWorksheet("변경 이력", { views: [{ state: "frozen", ySplit: 1 }] });
    historySheet.addRow(["처리일시", "대상 날짜", "직원명", "처리유형", "변경항목", "변경 전", "변경 후", "사유", "처리자", "권한"]);
    monthAuditLogs.forEach((log) => historySheet.addRow([formatDate(log.created_at) + " " + formatTime(log.created_at), log.target_work_date || rows.find((record) => record.id === log.attendance_record_id)?.work_date || "", log.employee_name || "", log.action_type, log.changed_field, log.before_value, log.after_value, log.reason, log.changed_by_name || "", log.changed_by_role || ""]));
    historySheet.columns = [{ width: 21 }, { width: 13 }, { width: 12 }, { width: 20 }, { width: 20 }, { width: 28 }, { width: 28 }, { width: 28 }, { width: 12 }, { width: 12 }];
    historySheet.autoFilter = { from: "A1", to: "J1" };
    historySheet.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
    historySheet.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF173F35" } };
    historySheet.eachRow((row) => { row.alignment = { vertical: "middle", wrapText: true }; row.eachCell((cell) => { cell.border = { bottom: { style: "thin", color: { argb: "FFD5DBD7" } } }; }); });

    const summary = workbook.addWorksheet("직원별 요약");
    summary.addRow(["직원명", "사무실 근무일", "총 근무일", "휴가 사용", "승인 시간외", "대체휴무 사용", "출장", "병가"]);
    const employees = profiles.filter((person) => person.role === "employee");
    employees.forEach((person) => {
      const personRows = rows.filter((row) => row.employee_id === person.id);
      const officeDays = personRows.filter((row) => row.clock_in_at && (row.clock_in_location_status === "inside" || row.clock_in_ip_matched)).length;
      const tripDates = new Set(personRows.filter((row) => row.work_type === "business_trip" || row.attendance_status === "business_trip").map((row) => row.work_date));
      const workedDates = new Set(personRows.filter((row) => row.clock_in_at || tripDates.has(row.work_date) || row.attendance_status === "education").map((row) => row.work_date));
      summary.addRow([person.name, officeDays, workedDates.size, leaveDays(requests, person.id, selectedMonth, "annual_leave"), formatMinutes(personRows.reduce((sum, row) => sum + regularApprovedOvertimeMinutes(row, requests), 0) + approvedEmergencyMinutesForEmployeeMonth(requests, person.id, selectedMonth)), formatMinutes(compTimeMinutes(requests, person.id, selectedMonth)), tripDates.size, leaveDays(requests, person.id, selectedMonth, "sick_leave")]);
    });
    summary.columns = [{ width: 14 }, { width: 16 }, { width: 14 }, { width: 14 }, { width: 16 }, { width: 18 }, { width: 12 }, { width: 12 }];
    summary.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
    summary.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF173F35" } };
    summary.getRow(1).height = 26;
    summary.views = [{ state: "frozen", ySplit: 1 }];
    summary.eachRow((row) => { row.alignment = { vertical: "middle", horizontal: "center" }; row.eachCell((cell) => { cell.border = { top: { style: "thin", color: { argb: "FFB8C5C0" } }, left: { style: "thin", color: { argb: "FFB8C5C0" } }, bottom: { style: "thin", color: { argb: "FFB8C5C0" } }, right: { style: "thin", color: { argb: "FFB8C5C0" } } }; }); });

    const year = Number(selectedMonth.slice(0, 4));
    const month = Number(selectedMonth.slice(5, 7));
    const daysInMonth = new Date(year, month, 0).getDate();
    const dayFormatter = new Intl.DateTimeFormat("ko-KR", { weekday: "short", timeZone: "Asia/Seoul" });
    employees.forEach((person, employeeIndex) => {
      const safeName = `${person.name}_${month}월`.replace(/[\\/:*?"<>|]/g, "_").slice(0, 31);
      const sheet = workbook.addWorksheet(safeName, { views: [{ state: "frozen", ySplit: 5 }] });
      sheet.columns = [{ width: 8 }, { width: 8 }, { width: 12 }, { width: 12 }, { width: 9 }, { width: 14 }, { width: 11 }, { width: 14 }, { width: 10 }, { width: 10 }, { width: 42 }];
      sheet.mergeCells("A1:K1");
      sheet.getCell("A1").value = `${year}년 ${month}월 ${person.name} 출근부 및 시간외근무 대장`;
      sheet.getCell("A1").font = { bold: true, size: 16 };
      sheet.getCell("A1").alignment = { horizontal: "center", vertical: "middle" };
      sheet.getRow(1).height = 30;
      sheet.mergeCells("J2:K2"); sheet.getCell("J2").value = "결재";
      sheet.getCell("J3").value = "담당";
      sheet.getCell("J4").value = "소장";
      sheet.getCell("A4").value = "직위";
      sheet.mergeCells("B4:C4"); sheet.getCell("B4").value = "";
      sheet.getCell("D4").value = "성명";
      sheet.mergeCells("E4:F4"); sheet.getCell("E4").value = person.name;
      sheet.getRow(2).height = 22;
      sheet.getRow(3).height = 34;
      sheet.getRow(4).height = 34;
      const headers = ["일자", "요일", "출근시간", "퇴근시간", "출근", "시간외근무", "대휴", "휴가", "출장", "병가", "비고"];
      sheet.getRow(5).values = headers;
      sheet.getRow(5).font = { bold: true };
      sheet.getRow(5).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFE7EFEC" } };
      sheet.getRow(5).height = 30;
      let totalAttendanceDays = 0;
      let totalOvertimeHours = 0;
      let totalCompHours = 0;
      let totalLeaveDays = 0;
      let totalTripDays = 0;
      let totalSickDays = 0;
      for (let day = 1; day <= daysInMonth; day += 1) {
        const workDate = `${selectedMonth}-${String(day).padStart(2, "0")}`;
        const record = rows.find((row) => row.employee_id === person.id && row.work_date === workDate);
        const dayRequests = requests.filter((request) => request.employee_id === person.id && request.status === "approved" && request.target_date <= workDate && (request.end_date || request.target_date) >= workDate);
        const annual = dayRequests.find((request) => request.request_type === "annual_leave");
        const specialLeave = dayRequests.find((request) => request.request_type === "special_leave");
        const otherLeave = dayRequests.find((request) => request.request_type === "other_leave");
        const comp = dayRequests.find((request) => request.request_type === "comp_time");
        const sick = dayRequests.find((request) => request.request_type === "sick_leave");
        const tripRequest = dayRequests.find((request) => request.request_type === "business_trip");
        const overtimeRequest = dayRequests.find((request) => request.request_type === "overtime");
        const trip = Boolean(tripRequest) || record?.work_type === "business_trip" || record?.attendance_status === "business_trip" || exceptions.some((item) => item.employee_id === person.id && item.exception_type === "business_trip" && !item.cancelled_at && item.start_date <= workDate && item.end_date >= workDate);
        const date = new Date(`${workDate}T12:00:00+09:00`);
        const holidayName = holidayMap.get(workDate);
        const annualMinutes = annual ? approvedRequestMinutesForDate(annual, workDate, Boolean(holidayName)) : 0;
        const specialLeaveMinutes = specialLeave ? approvedRequestMinutesForDate(specialLeave, workDate, Boolean(holidayName)) : 0;
        const otherLeaveMinutes = otherLeave ? approvedRequestMinutesForDate(otherLeave, workDate, Boolean(holidayName)) : 0;
        const compMinutes = comp ? approvedRequestMinutesForDate(comp, workDate, Boolean(holidayName)) : 0;
        const sickMinutes = sick ? approvedRequestMinutesForDate(sick, workDate, Boolean(holidayName)) : 0;
        const emergencyMinutes = approvedEmergencyMinutesForEmployeeDate(requests, person.id, workDate);
        const regularOvertimeMinutes = record ? regularApprovedOvertimeMinutes(record, requests) : 0;
        const overtimeHours = record ? totalApprovedOvertimeMinutes(record, requests) / 60 : 0;
        const compHours = compMinutes / 60;
        const leaveDayValue = (annualMinutes + specialLeaveMinutes + otherLeaveMinutes) / 480;
        const sickDayValue = sickMinutes ? sickMinutes / 480 : record?.leave_type === "sick_leave" ? 1 : 0;
        const overtimeAudit = record ? monthAuditLogs.find((log) => log.attendance_record_id === record.id && log.action_type === "overtime_review") : undefined;
        const overtimeReason = overtimeRequest?.reason || overtimeAudit?.reason || "업무내용 추가 확인 필요";
        const compSource = comp ? compTimeSources.get(comp.id) || [] : [];
        const compDetail = compMinutes > 0 ? `대체휴무 ${formatMinutes(compMinutes)} 사용, ${compSource.length > 0 ? compSource.join(", ") + "에 따른 휴무" : "발생 시간외근무 연결 필요"}` : "";
        const annualDetail = annualMinutes > 0 ? `${leaveUnitLabel(annualMinutes)} 사용` : "";
        const specialLeaveDetail = specialLeaveMinutes > 0 ? `${specialLeave?.request_subtype || "특별휴가"} ${formatMinutes(specialLeaveMinutes)} 사용` : "";
        const otherLeaveDetail = otherLeaveMinutes > 0 ? `${otherLeave?.request_subtype || "기타 휴가"} ${formatMinutes(otherLeaveMinutes)} 사용` : "";
        const sickDetail = sickMinutes > 0 ? `병가 ${Number((sickMinutes / 480).toFixed(3))}일 사용` : "";
        const overtimeDetail = regularOvertimeMinutes > 0 ? `일반 시간외근무 ${formatMinutes(regularOvertimeMinutes)}, 업무내용: ${overtimeReason}` : "";
        const emergencyDetail = emergencySupportRemarkForEmployeeDate(requests, person.id, workDate);
        const cleanRecordNote = attendanceNoteWithoutEmergency(record?.note);
        const tripDetail = trip ? `출장${tripRequest?.reason ? `, 사유: ${tripRequest.reason}` : cleanRecordNote ? `, 사유: ${cleanRecordNote}` : ""}` : "";
        const remarks = [...new Set([holidayName || ([0, 6].includes(date.getDay()) ? "주말" : ""), overtimeDetail, emergencyDetail, compDetail, annualDetail, specialLeaveDetail, otherLeaveDetail, sickDetail, tripDetail].filter(Boolean))].join("\n");
        const row = sheet.addRow([day, dayFormatter.format(date), record?.clock_in_at ? formatTime(record.clock_in_at) : "", record ? formatTime(effectiveClockOutAt(record, requests)) : "", record?.clock_in_at ? "✓" : "", overtimeHours || "", compHours || "", leaveDayValue || "", trip ? "✓" : "", sickDayValue || "", remarks]);
        const remarkLineCount = remarks ? remarks.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 32)), 0) : 1;
        row.height = Math.min(82, Math.max(23, remarkLineCount * 16));
        totalAttendanceDays += record?.clock_in_at ? 1 : 0;
        totalOvertimeHours += overtimeHours;
        totalCompHours += compHours;
        totalLeaveDays += leaveDayValue;
        totalTripDays += trip ? 1 : 0;
        totalSickDays += sickDayValue;
        [[6, overtimeHours, "시간", 2], [7, compHours, "시간", 2], [8, leaveDayValue, "일", 3], [10, sickDayValue, "일", 3]].forEach(([column, value, unit, decimals]) => {
          if (typeof value === "number" && value > 0) sheet.getCell(row.number, Number(column)).numFmt = Number.isInteger(value) ? `0"${unit}"` : `0.${"#".repeat(Number(decimals))}"${unit}"`;
        });
        if (holidayName || [0, 6].includes(date.getDay())) row.eachCell({ includeEmpty: true }, (cell) => { cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFF3F4F4" } }; });
      }
      const totalRow = sheet.addRow(["총계", "", "", "", totalAttendanceDays, totalOvertimeHours, totalCompHours, totalLeaveDays, totalTripDays, totalSickDays, ""]);
      sheet.mergeCells(`A${totalRow.number}:D${totalRow.number}`);
      totalRow.font = { bold: true };
      totalRow.eachCell({ includeEmpty: true }, (cell) => { cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFDDE9E5" } }; });
      [[6, totalOvertimeHours, "시간", 2], [7, totalCompHours, "시간", 2], [8, totalLeaveDays, "일", 3], [10, totalSickDays, "일", 3]].forEach(([column, value, unit, decimals]) => {
        sheet.getCell(totalRow.number, Number(column)).numFmt = typeof value === "number" && Number.isInteger(value) ? `0"${unit}"` : `0.${"#".repeat(Number(decimals))}"${unit}"`;
      });
      sheet.getCell(totalRow.number, 5).numFmt = '0"일"';
      sheet.getCell(totalRow.number, 9).numFmt = '0"일"';
      for (let rowIndex = 2; rowIndex <= totalRow.number; rowIndex += 1) for (let columnIndex = 1; columnIndex <= 11; columnIndex += 1) {
        const cell = sheet.getCell(rowIndex, columnIndex);
        cell.alignment = { horizontal: "center", vertical: "middle", wrapText: true };
        const isApprovalCell = rowIndex >= 2 && rowIndex <= 4 && columnIndex >= 10;
        const isEmployeeCell = rowIndex === 4 && columnIndex <= 6;
        const isTableCell = rowIndex >= 5;
        if (isApprovalCell || isEmployeeCell || isTableCell) cell.border = { top: { style: "thin", color: { argb: "FF363D3A" } }, left: { style: "thin", color: { argb: "FF363D3A" } }, bottom: { style: "thin", color: { argb: "FF363D3A" } }, right: { style: "thin", color: { argb: "FF363D3A" } } };
      }
      sheet.pageSetup = { orientation: "portrait", fitToPage: true, fitToWidth: 1, fitToHeight: 1, paperSize: 9, margins: { left: 0.25, right: 0.25, top: 0.35, bottom: 0.35, header: 0.1, footer: 0.1 } };
      sheet.headerFooter.oddFooter = `&L${tenantBranding.title}&C${year}년 ${month}월&R${employeeIndex + 1}/${employees.length}`;
    });
    const buffer = await workbook.xlsx.writeBuffer();
    downloadBlob(new Blob([buffer], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }), `${selectedMonth}_직원별_월간출근부.xlsx`);
  }

  function downloadBlob(blob: Blob, fileName: string) {
    const url = URL.createObjectURL(blob); const anchor = document.createElement("a");
    anchor.href = url; anchor.download = fileName; anchor.click(); URL.revokeObjectURL(url);
  }

  function changeSelectedMonth(value: string) {
    if (isSupabaseConfigured) setDataReady(false);
    setMonthClosing(null);
    setSelectedMonth(value);
  }

  if (isSupabaseConfigured && (!authReady || Boolean(profile && !dataReady))) return <AppLoadingScreen branding={tenantBranding} />;
  if (isSupabaseConfigured && !profile) return <><UnifiedLoginScreen branding={tenantBranding} identifier={loginIdentifier} password={loginPassword} error={loginError} busy={busy} showInstall={Boolean(installPrompt) || iosInstallAvailable} onInstall={() => void installApp()} onIdentifier={setLoginIdentifier} onPassword={setLoginPassword} onLogin={login} onReset={resetPassword} />{installGuideOpen && <IosInstallGuide onClose={() => setInstallGuideOpen(false)} />}</>;

  const employeeNav = [
    { id: "today" as const, label: "오늘", icon: Clock3 }, { id: "records" as const, label: "내 기록", icon: CalendarDays }, { id: "corrections" as const, label: "내 신청내역", icon: PencilLine },
    ...(currentProfile?.can_view_reports ? [{ id: "team_reports" as const, label: "직원 현황", icon: Download }, { id: "report_audit" as const, label: "변경 이력", icon: History }] : []),
  ];
  const adminNav = effectiveRole === "super_admin"
    ? [{ id: "organizations" as const, label: "기관 관리", icon: Building2 }, { id: "org_reports" as const, label: "기관별 근태", icon: CalendarDays }, { id: "approvals" as const, label: "변경 승인", icon: ShieldCheck }, { id: "audit" as const, label: "변경 이력", icon: History }, { id: "settings" as const, label: "내 화면 설정", icon: Settings }]
    : [{ id: "dashboard" as const, label: "대시보드", icon: Building2 }, { id: "monthly" as const, label: "근태 기록", icon: CalendarDays }, { id: "leave_balances" as const, label: "휴가와 대휴", icon: FileClock }, { id: "exceptions" as const, label: "출장과 예외", icon: FileClock }, { id: "requests" as const, label: "신청 승인", icon: PencilLine }, { id: "audit" as const, label: "변경 이력", icon: History }, { id: "settings" as const, label: "설정", icon: Settings }];
  const selectedOrganization = organizations.find((item) => item.id === selectedOrgId) || null;

  return (
    <div className="app-shell">
      <aside className={`sidebar ${menuOpen ? "sidebar-open" : ""}`}>
        <BrandIdentity branding={tenantBranding} />
        {!isSupabaseConfigured && <div className="demo-switch" role="group" aria-label="화면 미리보기"><button className={effectiveRole === "employee" ? "active" : ""} onClick={() => { setRolePreview("employee"); setMenuOpen(false); }}>직원 화면</button><button className={isAdminRole(effectiveRole) ? "active" : ""} onClick={() => { setRolePreview("super_admin"); setMenuOpen(false); }}>관리자 화면</button></div>}
        <nav aria-label="주요 메뉴">
          <span className="nav-label">{isAdminRole(effectiveRole) ? "관리" : "내 근태"}</span>
          {(isAdminRole(effectiveRole) ? adminNav : employeeNav).map((item) => {
            const active = isAdminRole(effectiveRole) ? adminView === item.id : employeeView === item.id;
            return <button key={item.id} className={`nav-item ${active ? "active" : ""}`} onClick={() => { if (isAdminRole(effectiveRole)) setAdminView(item.id as AdminView); else setEmployeeView(item.id as EmployeeView); setMenuOpen(false); }}><item.icon size={20} /><span>{item.label}</span>{item.id === "requests" && requests.filter((request) => request.status === "pending").length > 0 && <em>{requests.filter((request) => request.status === "pending").length}</em>}</button>;
          })}
        </nav>
        <div className="privacy-note"><ShieldCheck size={19} /><p><strong>위치는 기록 순간에만 확인합니다.</strong><span>이동경로나 실시간 위치를 추적하지 않습니다.</span></p></div>
        <div className="sidebar-user">{isAdminRole(effectiveRole) && <div className="avatar">{tenantBranding.mark}</div>}<div><strong>{currentProfile?.name}</strong><span>{currentProfile?.department || currentProfile?.employee_number}</span></div>{isSupabaseConfigured && <div className="sidebar-user-actions"><button aria-label="비밀번호 변경" title="비밀번호 변경" onClick={() => { setPasswordRecovery(false); setPasswordOpen(true); }}><KeyRound size={18} /></button><button aria-label="로그아웃" title="로그아웃" onClick={() => { setLoginPassword(""); void supabase?.auth.signOut({ scope: "local" }); }}><LogOut size={18} /></button></div>}</div>
        {isAdminRole(effectiveRole) ? <SupportContact compact /> : <InstitutionSupportNotice compact />}
      </aside>
      <main className="main-content">
        <header className="topbar"><button className="menu-button" onClick={() => setMenuOpen((open) => !open)} aria-label="메뉴 열기"><Menu /></button><div><strong>{isAdminRole(effectiveRole) ? adminNav.find((item) => item.id === adminView)?.label : employeeNav.find((item) => item.id === employeeView)?.label}</strong><span>{formatDate(now)}</span></div>{effectiveRole === "super_admin" && organizations.length > 0 && <label className="organization-switcher"><span>조회 기관</span><select value={selectedOrgId} onChange={(event) => setSelectedOrgId(event.target.value)}>{organizations.map((item) => <option key={item.id} value={item.id}>{item.short_name}</option>)}</select></label>}{(installPrompt || iosInstallAvailable) && <button className="install-button" onClick={() => void installApp()}><Download size={16} /> 앱 설치</button>}{!isSupabaseConfigured && <Badge tone="active">데모 모드</Badge>}</header>
        {notice && <div className={`notice notice-${notice.tone}`} role="status">{notice.tone === "success" ? <CheckCircle2 /> : notice.tone === "error" ? <XCircle /> : <AlertCircle />}<span>{notice.text}</span><button onClick={() => setNotice(null)} aria-label="알림 닫기"><X /></button></div>}
        <div className="page-wrap">
          {effectiveRole === "super_admin" && adminView === "organizations" && <OrganizationManagement organizations={organizations} organizationAdmins={organizationAdmins} organizationEmployees={organizationEmployees} selectedOrganization={selectedOrganization} selectedOrgId={selectedOrgId} selectedOrgWorkplace={selectedOrgWorkplace} selectedOrgSettings={selectedOrgSettings} onSelect={setSelectedOrgId} onCreateOrganization={(form) => void createOrganization(form)} onCreateAdmin={(form) => void createOrganizationAdmin(form)} onUpdateAdmin={updateOrganizationAdmin} onDeleteAdmin={deleteOrganizationAdmin} onEditEmployee={setEditingEmployee} onUpdateOrganization={(form) => void updateOrganization(form)} onUpdateProtection={(form) => void updateSelectedOrganizationProtection(form)} onDeactivateOrganization={() => void deactivateOrganization()} onReactivateOrganization={() => void reactivateOrganization()} busy={busy} />}
          {effectiveRole === "super_admin" && adminView === "org_reports" && selectedOrganization && <ReportViewer superAdmin records={monthlyRows} summaryRecords={allMonthRows} requests={requests} exceptions={exceptions} overtimeAfterComp={[]} month={selectedMonth} closing={monthClosing} profiles={profiles} employeeFilter={employeeFilter} statusFilter={statusFilter} onMonth={changeSelectedMonth} onEmployee={setEmployeeFilter} onStatus={setStatusFilter} onCsv={() => exportCsv(monthlyRows)} onExcel={() => void exportExcel(allMonthRows)} onPrint={() => window.print()} />}
          {effectiveRole === "super_admin" && adminView === "approvals" && <OrganizationApprovalView requests={organizationChangeRequests} organizations={organizations} busy={busy} onReview={(request, decision) => void reviewOrganizationChange(request, decision)} onReopen={(request) => void reopenOrganizationChange(request)} />}
          {effectiveRole === "super_admin" && adminView === "settings" && currentProfile && <SuperAdminSettingsView profile={currentProfile} branding={superAdminBranding} onSaveAccount={(form) => void updateSuperAdminEmployeeNumber(form)} onSaveBranding={(form) => void updateSuperAdminBranding(form)} onUploadLogo={uploadSuperAdminLogo} onPurgeRetention={() => void purgeExpiredAttendanceData()} busy={busy} />}
          {!isAdminRole(effectiveRole) && employeeView === "today" && <TodayView now={now} record={todayRecord || openRecord} exception={openRecord ? undefined : todayException} workplace={workplace} busy={busy} locationResult={locationResult} onClock={startClock} />}
          {!isAdminRole(effectiveRole) && employeeView === "records" && <EmployeeRecords records={myRecords} requests={myRequests} exceptions={myExceptions} compTimeBalance={compTimeBalances.find((item) => item.employee_id === currentProfile?.id)} annualLeaveBalance={annualLeaveBalances.find((item) => item.employee_id === currentProfile?.id && item.valid_from <= currentDateKey() && item.valid_to >= currentDateKey())} overtimeAfterComp={monthlyOvertimeAfterComp.find((item) => item.employee_id === currentProfile?.id)} month={selectedMonth} onMonth={changeSelectedMonth} onCorrection={() => setCorrectionOpen(true)} />}
          {!isAdminRole(effectiveRole) && employeeView === "corrections" && <EmployeeCorrections requests={myRequests} activeEmergencyRequest={activeEmergencyRequest} emergencySupportEnabled={organizationSettingsDraft.emergency_support_enabled} onNew={() => setCorrectionOpen(true)} onEmergencyWork={() => setEmployeeEmergencyWorkOpen(true)} onEditRequest={setEditingRequest} />}
          {!isAdminRole(effectiveRole) && currentProfile?.can_view_reports && employeeView === "team_reports" && <ReportViewer records={monthlyRows} summaryRecords={allMonthRows} requests={requests} exceptions={exceptions} overtimeAfterComp={monthlyOvertimeAfterComp} month={selectedMonth} closing={monthClosing} profiles={profiles} employeeFilter={employeeFilter} statusFilter={statusFilter} onMonth={changeSelectedMonth} onEmployee={setEmployeeFilter} onStatus={setStatusFilter} onCsv={() => exportCsv(monthlyRows)} onExcel={() => void exportExcel(allMonthRows)} onPrint={() => window.print()} />}
          {!isAdminRole(effectiveRole) && currentProfile?.can_view_reports && employeeView === "report_audit" && <AuditView logs={auditLogs} brandTitle={tenantBranding.title} />}
          {isAdminRole(effectiveRole) && adminView === "dashboard" && <AdminDashboard records={records} requests={requests} profiles={profiles} onMonthly={() => setAdminView("monthly")} onRequests={() => setAdminView("requests")} onConfirm={(record) => void confirmAttendanceRecord(record)} />}
          {isAdminRole(effectiveRole) && adminView === "monthly" && <MonthlyAdmin records={monthlyRows} summaryRecords={allMonthRows} requests={requests} exceptions={exceptions} overtimeAfterComp={monthlyOvertimeAfterComp} month={selectedMonth} closing={monthClosing} canReopen={effectiveRole === "super_admin"} profiles={profiles} employeeFilter={employeeFilter} statusFilter={statusFilter} onMonth={changeSelectedMonth} onEmployee={setEmployeeFilter} onStatus={setStatusFilter} onCsv={() => exportCsv(monthlyRows)} onExcel={() => void exportExcel(allMonthRows)} onPrint={() => window.print()} onClose={closeMonth} onReopen={() => void reopenMonth()} onCreate={() => setAttendanceCreateOpen(true)} onEdit={setEditingRecord} onDelete={(record) => void deleteAttendanceRecord(record)} onOvertime={(record, decision) => void reviewOvertime(record, decision)} onOvertimeReopen={(record) => void reopenOvertimeReview(record)} onConfirm={(record) => void confirmAttendanceRecord(record)} onLeave={setLeaveApplyingRecord} />}
          {isAdminRole(effectiveRole) && adminView === "leave_balances" && <LeaveBalanceAdmin profiles={profiles} annualBalances={annualLeaveBalances} compBalances={compTimeBalances} credits={compTimeCredits} onSaveAnnual={(form) => void saveAnnualLeaveEntitlement(form)} onDeleteAnnual={(entitlement) => void deleteAnnualLeaveEntitlement(entitlement)} onSaveComp={(form) => void saveCompTimeCredit(form)} onDeleteComp={(credit) => void deleteCompTimeCredit(credit)} onExtend={(credit) => void extendCompTimeCredit(credit)} />}
          {isAdminRole(effectiveRole) && adminView === "exceptions" && <ExceptionAdmin exceptions={exceptions} onNew={() => setExceptionOpen(true)} onCancel={(item) => void cancelAttendanceException(item)} />}
          {isAdminRole(effectiveRole) && adminView === "requests" && <RequestAdminWorkspace requests={requests} records={records} emergencySupportEnabled={organizationSettingsDraft.emergency_support_enabled} onReview={reviewRequest} onReopen={(request) => void reopenRequest(request)} onEditRequest={setEditingRequest} onEditRecord={setEditingRecord} onEmergencyWork={() => setEmergencyWorkOpen(true)} />}
          {isAdminRole(effectiveRole) && adminView === "audit" && <AuditView logs={auditLogs} brandTitle={tenantBranding.title} onRestore={(log) => void restoreAttendanceRecord(log)} superAdmin={effectiveRole === "super_admin"} selectedOrgId={effectiveRole === "super_admin" ? selectedOrgId : currentProfile?.org_id || ""} organizations={organizations} organizationChanges={organizationChangeRequests} />}
          {isAdminRole(effectiveRole) && effectiveRole !== "super_admin" && adminView === "settings" && <SettingsView branding={tenantOrganization} draft={settingsDraft} organizationDraft={organizationSettingsDraft} setOrganizationDraft={setOrganizationSettingsDraft} workPolicy={workPolicyDraft} setWorkPolicy={setWorkPolicyDraft} shiftTemplates={shiftTemplates} shiftAssignments={shiftAssignments} organizationChangeRequests={organizationChangeRequests} profiles={profiles} canResetPasswords={["admin", "org_admin"].includes(effectiveRole)} onResetPassword={setResetPasswordTarget} onCreateEmployee={() => setEmployeeCreateOpen(true)} onEditEmployee={setEditingEmployee} onSetEmployeeActive={(person, active) => void setEmployeeActive(person, active)} onToggleReportViewer={(person) => void toggleReportViewer(person)} onSave={saveSettings} onSaveBranding={(form) => void updateOrganizationBranding(form)} onUploadLogo={(file) => uploadOrganizationLogo(file)} onSaveWorkPolicy={() => void saveWorkPolicy()} onCreateShift={(form) => void createShiftTemplate(form)} onSetShiftActive={(template, active) => void setShiftTemplateActive(template, active)} onAssignShift={(form) => void assignEmployeeShift(form)} onRemoveAssignment={(assignment) => void removeShiftAssignment(assignment)} onRequestOrganizationChange={(form, type) => void requestOrganizationChange(form, type)} holidayYear={holidayYear} holidays={holidays} onHolidayYear={setHolidayYear} onSyncHolidays={() => void syncHolidays()} onAddHoliday={() => void addCustomHoliday()} onEditHoliday={(holiday) => void editHoliday(holiday)} onRemoveHoliday={(holiday) => void removeHoliday(holiday)} busy={busy} />}
        </div>
      </main>
      {menuOpen && <button className="scrim" aria-label="메뉴 닫기" onClick={() => setMenuOpen(false)} />}
      {consentOpen && <ConsentModal onCancel={() => { setConsentOpen(false); setPendingClockAction(null); }} onAgree={() => void acceptLocationConsent()} />}
      {correctionOpen && <CorrectionModal records={myRecords} onClose={() => setCorrectionOpen(false)} onSubmit={submitCorrection} />}
      {editingRecord && <AttendanceEditModal record={editingRecord} onClose={() => setEditingRecord(null)} onSubmit={updateAttendanceRecord} />}
      {editingRequest && <AttendanceRequestEditModal request={editingRequest} canChangeType={isAdminRole(effectiveRole)} onClose={() => setEditingRequest(null)} onSubmit={updateAttendanceRequest} />}
      {exceptionOpen && <ExceptionModal profiles={profiles} onClose={() => setExceptionOpen(false)} onSubmit={createAttendanceException} />}
      {attendanceCreateOpen && <AttendanceCreateModal profiles={profiles} month={selectedMonth} onClose={() => setAttendanceCreateOpen(false)} onSubmit={(form) => void createAttendanceRecord(form)} />}
      {emergencyWorkOpen && organizationSettingsDraft.emergency_support_enabled && <EmergencySupportWorkModal profiles={profiles} busy={busy} onClose={() => setEmergencyWorkOpen(false)} onSubmit={(form) => void createEmergencySupportWork(form)} />}
      {employeeEmergencyWorkOpen && (organizationSettingsDraft.emergency_support_enabled || activeEmergencyRequest) && <EmployeeEmergencySupportControlModal activeRequest={activeEmergencyRequest} busy={busy} onClose={() => setEmployeeEmergencyWorkOpen(false)} onPastSubmit={(form) => void submitCorrection(form)} onStart={(form) => void startEmergencySupportWork(form)} onFinish={(form, request) => void finishEmergencySupportWork(form, request)} onEdit={(request) => { setEmployeeEmergencyWorkOpen(false); setEditingRequest(request); }} onCancel={(request) => void cancelEmergencySupportWork(request)} />}
      {leaveApplyingRecord && <LeaveApplyModal record={leaveApplyingRecord} defaultEndTime={organizationSettingsDraft.default_end_time.slice(0, 5)} onClose={() => setLeaveApplyingRecord(null)} onSubmit={(form) => void applyLeaveToAttendanceRecord(leaveApplyingRecord, form)} />}
      {passwordOpen && currentProfile && <PasswordChangeModal recovery={passwordRecovery} privileged={isAdminRole(effectiveRole)} busy={busy} onClose={() => { if (!passwordRecovery) setPasswordOpen(false); }} onSubmit={changeOwnPassword} />}
      {resetPasswordTarget && <AdminResetPasswordModal profile={resetPasswordTarget} busy={busy} onClose={() => setResetPasswordTarget(null)} onSubmit={resetEmployeePassword} />}
      {employeeCreateOpen && <EmployeeCreateModal busy={busy} onClose={() => setEmployeeCreateOpen(false)} onSubmit={createEmployee} />}
      {editingEmployee && <EmployeeEditModal profile={editingEmployee} busy={busy} onClose={() => setEditingEmployee(null)} onSubmit={updateEmployee} />}
      {installGuideOpen && <IosInstallGuide onClose={() => setInstallGuideOpen(false)} />}
      {retentionPreview && <RetentionCleanupModal preview={retentionPreview} busy={busy} onClose={() => setRetentionPreview(null)} onConfirm={() => void confirmPurgeExpiredAttendanceData()} />}
    </div>
  );
}

function UnifiedLoginScreen({ branding, identifier, password, error, busy, showInstall, onInstall, onIdentifier, onPassword, onLogin, onReset }: { branding: OrganizationBranding; identifier: string; password: string; error: string; busy: boolean; showInstall: boolean; onInstall: () => void; onIdentifier: (value: string) => void; onPassword: (value: string) => void; onLogin: (event: React.FormEvent) => void; onReset: () => void }) {
  return <main className="login-page">
    <section className="login-panel">
      <BrandIdentity branding={branding} login />
      {showInstall && <button type="button" className="install-button login-install-button" onClick={onInstall}><Download size={16} /> 앱 설치 안내</button>}
      <div className="login-heading"><Badge tone="positive"><ShieldCheck size={14} /> 내부 직원 전용</Badge><h1>오늘도 안전하게,<br />간단하게 기록하세요.</h1><p>모든 계정은 사번으로 로그인할 수 있으며, 최고관리자는 이메일도 사용할 수 있습니다.</p></div>
      <form className="login-form" onSubmit={onLogin} autoComplete="off">
        <label>아이디<input value={identifier} onChange={(event) => onIdentifier(event.target.value)} placeholder="사번 또는 최고관리자 이메일" autoComplete="username" required /></label>
        <label>비밀번호<input name="attendance-login-password" type="password" value={password} onChange={(event) => onPassword(event.target.value)} autoComplete="off" required /></label>
        {error && <div className="form-message"><AlertCircle size={17} />{error}</div>}
        <button className="primary-button" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <LogIn />} 로그인</button>
        <button type="button" className="text-button" onClick={onReset}>비밀번호를 잊으셨나요?</button>
        <p className="login-help">사번을 입력하면 소속 기관과 권한을 자동으로 확인합니다. 비밀번호 초기화는 상위 관리자에게 요청해 주세요.</p>
      </form>
      <div className="login-privacy"><LocateFixed /><p><strong>상시 위치 추적 없음</strong><span>출근과 퇴근 버튼을 누를 때만 위치정보를 확인합니다.</span><span>로그인은 이 브라우저에 유지됩니다. 공용 컴퓨터에서는 사용 후 로그아웃해 주세요.</span></p></div>
    </section>
    <section className="login-visual"><div className="visual-orbit orbit-one" /><div className="visual-orbit orbit-two" /><div className="visual-card"><div className="visual-icon"><CheckCircle2 /></div><span>오늘의 기록</span><strong>출근 완료</strong><p>09:00, 사업장 반경 내</p></div></section>
  </main>;
}

function LoginScreen({ branding, identifier, password, error, busy, showInstall, onInstall, onIdentifier, onPassword, onLogin, onReset }: { branding: OrganizationBranding; identifier: string; password: string; error: string; busy: boolean; showInstall: boolean; onInstall: () => void; onIdentifier: (value: string) => void; onPassword: (value: string) => void; onLogin: (event: React.FormEvent) => void; onReset: () => void }) {
  return <main className="login-page"><section className="login-panel"><BrandIdentity branding={branding} login />{showInstall && <button type="button" className="install-button login-install-button" onClick={onInstall}><Download size={16} /> 앱 설치 안내</button>}<div className="login-heading"><Badge tone="positive"><ShieldCheck size={14} /> 내부 직원 전용</Badge><h1>오늘도 안전하게,<br />간단하게 기록하세요.</h1><p>직원과 기관관리자는 사번으로, 최고관리자는 이메일로 로그인합니다.</p></div><form className="login-form" onSubmit={onLogin}><label>아이디<input value={identifier} onChange={(event) => onIdentifier(event.target.value)} placeholder="사번 또는 최고관리자 이메일" autoComplete="username" required /></label><label>비밀번호<input type="password" value={password} onChange={(event) => onPassword(event.target.value)} autoComplete="current-password" required /></label>{error && <div className="form-message"><AlertCircle size={17} />{error}</div>}<button className="primary-button" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <LogIn />} 로그인</button><button type="button" className="text-button" onClick={onReset}>비밀번호를 잊으셨나요?</button><p className="login-help">사번을 입력하면 소속 기관과 권한을 자동으로 확인합니다. 비밀번호 초기화는 상위 관리자에게 요청해 주세요.</p></form><div className="login-privacy"><LocateFixed /><p><strong>상시 위치 추적 없음</strong><span>출근과 퇴근 버튼을 누를 때만 위치정보를 확인합니다.</span><span>로그인은 이 브라우저에 유지됩니다. 공용 컴퓨터에서는 사용 후 로그아웃해 주세요.</span></p></div></section><section className="login-visual"><div className="visual-orbit orbit-one" /><div className="visual-orbit orbit-two" /><div className="visual-card"><div className="visual-icon"><CheckCircle2 /></div><span>오늘의 기록</span><strong>출근 완료</strong><p>09:00, 사업장 반경 내</p></div></section></main>;
}

function OrganizationManagement({ organizations, organizationAdmins, organizationEmployees, selectedOrganization, selectedOrgId, selectedOrgWorkplace, selectedOrgSettings, onSelect, onCreateOrganization, onCreateAdmin, onUpdateAdmin, onDeleteAdmin, onEditEmployee, onUpdateOrganization, onUpdateProtection, onDeactivateOrganization, onReactivateOrganization, busy }: {
  organizations: Organization[];
  organizationAdmins: Profile[];
  organizationEmployees: Profile[];
  selectedOrganization: Organization | null;
  selectedOrgId: string;
  selectedOrgWorkplace: Workplace | null;
  selectedOrgSettings: OrganizationSettings | null;
  onSelect: (id: string) => void;
  onCreateOrganization: (form: HTMLFormElement) => void;
  onCreateAdmin: (form: HTMLFormElement) => void;
  onUpdateAdmin: (form: HTMLFormElement, profile: Profile) => Promise<boolean>;
  onDeleteAdmin: (profile: Profile) => Promise<boolean>;
  onEditEmployee: (profile: Profile) => void;
  onUpdateOrganization: (form: HTMLFormElement) => void;
  onUpdateProtection: (form: HTMLFormElement) => void;
  onDeactivateOrganization: () => void;
  onReactivateOrganization: () => void;
  busy: boolean;
}) {
  const selectedAdmins = organizationAdmins.filter((person) => person.org_id === selectedOrgId);
  const selectedEmployees = organizationEmployees.filter((person) => person.org_id === selectedOrgId);
  const [editingAdmin, setEditingAdmin] = useState<Profile | null>(null);
  return <section>
    <div className="page-heading"><div><span className="kicker">최고관리자</span><h1>기관과 기관 관리자</h1><p>기관을 추가한 뒤 해당 기관을 맡을 관리자 계정을 만듭니다. 근태자료는 기관을 선택한 상태에서만 조회합니다.</p></div><Badge tone="neutral">등록 기관 {organizations.length}곳</Badge></div>
    <form className="surface-card super-admin-create-card" onSubmit={(event) => { event.preventDefault(); onCreateOrganization(event.currentTarget); }}>
      <div className="card-heading"><div><span className="kicker">통합관리 독립 기능</span><h2>새 기관 만들기</h2></div><Building2 /></div>
      <p className="card-description">현재 선택한 기관과 관계없이 새 기관을 등록합니다. 기관을 선택해도 이 영역의 색상과 입력값은 바뀌지 않습니다.</p>
      <div className="form-grid"><label className="full">기관 공식명<input name="org_name" minLength={2} maxLength={100} placeholder="예: 여성의쉼터 불턱" required /></label><label>짧은 이름<input name="short_name" maxLength={50} placeholder="예: 불턱" required /></label><label>기관 코드<input name="org_code" pattern="[a-z0-9][a-z0-9-]{1,49}" placeholder="예: bulteok" required /></label><label className="full">접속 도메인, 선택<input name="domain" placeholder="전용 주소가 필요할 때만 입력" /></label></div>
      <div className="setting-info"><AlertCircle /><p>기관 고유정보는 데이터베이스에 저장됩니다. 도메인은 비워 두고 기관 코드로 로그인해도 됩니다.</p></div>
      <button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 기관 만들기</button>
    </form>
    <div className="organization-admin-layout">
      <article className="surface-card organization-list-card">
        <div className="card-heading"><div><span className="kicker">기관 목록</span><h2>조회 기관 선택</h2></div><Building2 /></div>
        <div className="organization-list">{organizations.map((item) => { const brand = organizationBranding(item); return <button type="button" key={item.id} className={selectedOrgId === item.id ? "active" : ""} onClick={() => { onSelect(item.id); setEditingAdmin(null); }}><span className="organization-mark" style={{ background: brand.primaryColor, color: readableTextColor(brand.primaryColor) }}>{brand.mark}</span><span><strong>{item.short_name}</strong><small>{item.org_name}</small><small>{item.domain || "전용 도메인 없음"}</small></span><Badge tone={item.is_active ? "positive" : "neutral"}>{item.is_active ? "사용 중" : "중지"}</Badge></button>; })}{organizations.length === 0 && <EmptyState title="등록된 기관이 없습니다" text="오른쪽에서 첫 기관을 만들어 주세요." />}</div>
      </article>
      <div className="organization-forms">
        <form className="surface-card" onSubmit={(event) => { event.preventDefault(); onCreateAdmin(event.currentTarget); }}>
          <div className="card-heading"><div><span className="kicker">기관 관리자</span><h2>{selectedOrganization ? `${selectedOrganization.short_name} 관리자 만들기` : "기관을 먼저 선택하세요"}</h2></div><Users /></div>
          <div className="form-grid"><label>이름<input name="name" minLength={2} maxLength={30} required disabled={!selectedOrganization} /></label><label>관리자 사번<input name="employee_number" pattern="[A-Za-z0-9-]{2,24}" required disabled={!selectedOrganization} /></label><label>임시 비밀번호<input name="password" type="password" minLength={8} required disabled={!selectedOrganization} /></label><label>비밀번호 확인<input name="confirm_password" type="password" minLength={8} required disabled={!selectedOrganization} /></label></div>
          <div className="setting-info"><ShieldCheck /><p>최초 관리자는 최고관리자가 만들고, 이후 관리자 교체와 중지는 승인 요청으로 처리합니다.</p></div>
          <button className="primary-button compact" disabled={busy || !selectedOrganization}>{busy ? <LoaderCircle className="spin" /> : <Users />} 관리자 계정 만들기</button>
        </form>
        {selectedOrganization && <article className="surface-card">
          <div className="card-heading"><div><span className="kicker">등록된 기관관리자</span><h2>{selectedOrganization.short_name} 관리자 목록</h2></div><Badge tone="neutral">{selectedAdmins.length}명</Badge></div>
          <div className="account-list organization-admin-list">{selectedAdmins.map((person) => <div key={person.id}><div className="avatar small">{person.name.slice(0, 1)}</div><p><strong>{person.name}</strong><span>로그인 사번 {person.employee_number}</span></p><Badge tone="positive">사용 중</Badge><button type="button" className="secondary-button" onClick={() => setEditingAdmin(person)} disabled={busy}><PencilLine size={16} /> 정보 수정</button><button type="button" className="reject-button" onClick={() => void onDeleteAdmin(person).then((deleted) => { if (deleted && editingAdmin?.id === person.id) setEditingAdmin(null); })} disabled={busy}><Trash2 size={16} /> 계정 삭제</button></div>)}{selectedAdmins.length === 0 && <EmptyState title="등록된 기관관리자가 없습니다" text="위의 관리자 계정 만들기에서 첫 관리자를 등록해 주세요." />}</div>
        </article>}
        {selectedOrganization && editingAdmin && <form key={editingAdmin.id} className="surface-card" onSubmit={(event) => { event.preventDefault(); void onUpdateAdmin(event.currentTarget, editingAdmin).then((updated) => { if (updated) setEditingAdmin(null); }); }}>
          <div className="card-heading"><div><span className="kicker">최고관리자 직접 변경</span><h2>{editingAdmin.name} 관리자 정보 수정</h2></div><PencilLine /></div>
          <p className="card-description">기관의 변경 요청 없이 최고관리자가 로그인 아이디, 사번, 이름과 비밀번호를 직접 바꿀 수 있습니다.</p>
          <div className="form-grid"><label className="full">계정 고유번호<input value={editingAdmin.id} disabled /></label><label>이름<input name="name" defaultValue={editingAdmin.name} minLength={2} maxLength={30} required /></label><label>관리자 사번<input name="employee_number" defaultValue={editingAdmin.employee_number} pattern="[A-Za-z0-9-]{2,24}" required /></label><label className="full">부서 또는 담당<input name="department" defaultValue={editingAdmin.department || "기관관리"} maxLength={50} /></label><label>새 비밀번호, 선택<input name="password" type="password" minLength={8} autoComplete="new-password" /></label><label>새 비밀번호 확인<input name="confirm_password" type="password" minLength={8} autoComplete="new-password" /></label></div>
          <div className="organization-edit-actions"><button type="button" className="secondary-button" onClick={() => setEditingAdmin(null)} disabled={busy}>취소</button><button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 관리자 정보 저장</button></div>
        </form>}
        {selectedOrganization && <article className="surface-card">
          <div className="card-heading"><div><span className="kicker">최고관리자 직접 변경</span><h2>{selectedOrganization.short_name} 직원 사번</h2></div><Badge tone="neutral">{selectedEmployees.length}명</Badge></div>
          <p className="card-description">기관관리자와 마찬가지로 최고관리자도 직원 이름, 부서와 사번을 수정할 수 있습니다. 기존 근태기록은 유지됩니다.</p>
          <div className="account-list">{selectedEmployees.map((person) => <div key={person.id}><div className="avatar small">{person.name.slice(0, 1)}</div><p><strong>{person.name}</strong><span>{person.employee_number}</span></p><Badge tone={person.is_active ? "positive" : "neutral"}>{person.is_active ? "재직" : "퇴사"}</Badge><button type="button" className="secondary-button" onClick={() => onEditEmployee(person)} disabled={busy}><PencilLine size={16} /> 사번과 정보 수정</button></div>)}</div>
        </article>}
        {selectedOrganization && <form key={selectedOrganization.id} className="surface-card" onSubmit={(event) => { event.preventDefault(); onUpdateOrganization(event.currentTarget); }}>
          <div className="card-heading"><div><span className="kicker">최고관리자 관리 항목</span><h2>{selectedOrganization.short_name} 기본정보</h2></div><Settings /></div>
          <div className="form-grid"><label className="full">기관 공식명<input name="org_name" defaultValue={selectedOrganization.org_name} minLength={2} maxLength={100} required /></label><label>짧은 이름<input name="short_name" defaultValue={selectedOrganization.short_name} maxLength={50} required /></label><label>기관 코드<input value={selectedOrganization.org_code} disabled /><small>기관과 기록을 연결하는 내부 값이므로 변경하지 않습니다.</small></label><label className="full">기관별 접속 도메인, 선택<input name="domain" defaultValue={selectedOrganization.domain || ""} placeholder="전용 주소가 필요할 때만 입력" /><small>직원은 도메인이나 기관명을 입력하지 않고 사번만으로 로그인할 수 있습니다.</small></label></div>
          <div className="setting-info"><ShieldCheck /><p>화면 제목, 로고와 색상은 각 기관관리자가 자기 기관 설정에서 변경합니다.</p></div>
          <div className="organization-edit-actions"><button className="primary-button compact" disabled={busy}><Check /> 기관 정보 저장</button>{selectedOrganization.is_active ? <button type="button" className="reject-button" onClick={onDeactivateOrganization} disabled={busy}><Trash2 size={16} /> 기관 사용 중지</button> : <button type="button" className="approve-button" onClick={onReactivateOrganization} disabled={busy}><RefreshCw size={16} /> 기관 다시 사용</button>}</div>
          <div className="setting-info"><ShieldCheck /><p>기관 사용 중지는 직원 로그인을 막지만 기존 근태기록과 변경 이력은 삭제하지 않습니다. 중지된 기관을 선택하면 기관 다시 사용 버튼이 표시됩니다.</p></div>
        </form>}
        {selectedOrganization && <SuperAdminProtectionSettings key={`${selectedOrganization.id}:${selectedOrgWorkplace?.id || "new"}`} organization={selectedOrganization} workplace={selectedOrgWorkplace} organizationSettings={selectedOrgSettings} onSave={onUpdateProtection} busy={busy} />}
      </div>
    </div>
  </section>;
}

function SuperAdminProtectionSettings({ organization, workplace, organizationSettings, onSave, busy }: { organization: Organization; workplace: Workplace | null; organizationSettings: OrganizationSettings | null; onSave: (form: HTMLFormElement) => void; busy: boolean }) {
  const fallback = { id: "", workplace_name: `${organization.short_name} 사업장`, latitude: 33.4996, longitude: 126.5312, allowed_radius_meters: 100, low_accuracy_threshold_meters: 100 };
  const [draft, setDraft] = useState<Workplace>(workplace || fallback);
  const [ip, setIp] = useState(organizationSettings?.office_ip_address || "");
  const [message, setMessage] = useState("");
  const [detecting, setDetecting] = useState<"location" | "ip" | null>(null);
  const unchanged = workplace !== null && organizationSettings !== null
    && draft.workplace_name.trim() === workplace.workplace_name.trim()
    && draft.latitude === workplace.latitude && draft.longitude === workplace.longitude
    && draft.allowed_radius_meters === workplace.allowed_radius_meters
    && draft.low_accuracy_threshold_meters === workplace.low_accuracy_threshold_meters
    && normalizeIpAddress(ip) === normalizeIpAddress(organizationSettings.office_ip_address);

  useEffect(() => {
    setDraft(workplace || fallback);
    setIp(organizationSettings?.office_ip_address || "");
    setMessage("");
  }, [organization.id, workplace, organizationSettings?.office_ip_address]);

  const detectLocation = async () => {
    setDetecting("location");
    const result = await requestCurrentLocation(draft);
    setDetecting(null);
    if (result.latitude == null || result.longitude == null) { setMessage(result.message); return; }
    setDraft((current) => ({ ...current, latitude: Number(result.latitude?.toFixed(6)), longitude: Number(result.longitude?.toFixed(6)) }));
    setMessage(`현재 위치를 입력했습니다${result.accuracy == null ? "" : `. 측정 오차 약 ${Math.round(result.accuracy)}m`}.`);
  };
  const detectIp = async () => {
    setDetecting("ip");
    const currentIp = await fetchClientIp();
    setDetecting(null);
    if (!currentIp) { setMessage("현재 공인 IP를 확인하지 못했습니다."); return; }
    setIp(currentIp);
    setMessage(normalizeIpAddress(currentIp) === normalizeIpAddress(organizationSettings?.office_ip_address || "") ? `현재 IP ${currentIp}는 이미 등록된 사무실 IP입니다.` : `현재 IP ${currentIp}를 입력했습니다.`);
  };

  return <form className="surface-card" onSubmit={(event) => { event.preventDefault(); onSave(event.currentTarget); }}>
    <div className="card-heading"><div><span className="kicker">최고관리자 즉시 변경</span><h2>{organization.short_name} 위치와 IP</h2></div><MapPin /></div>
    <p className="card-description">기관의 승인 요청 없이 바로 적용합니다. 변경 사유와 전후 값은 최고관리자와 해당 기관관리자의 변경 이력에 남습니다.</p>
    <div className="form-grid">
      <label className="full">사업장명<input name="workplace_name" value={draft.workplace_name} onChange={(event) => setDraft({ ...draft, workplace_name: event.target.value })} required /></label>
      <label>위도<input name="latitude" type="number" step="0.000001" value={draft.latitude} onChange={(event) => setDraft({ ...draft, latitude: Number(event.target.value) })} required /></label>
      <label>경도<input name="longitude" type="number" step="0.000001" value={draft.longitude} onChange={(event) => setDraft({ ...draft, longitude: Number(event.target.value) })} required /></label>
      <label>허용 반경<input name="allowed_radius_meters" type="number" min="50" max="1000" value={draft.allowed_radius_meters} onChange={(event) => setDraft({ ...draft, allowed_radius_meters: Number(event.target.value) })} required /></label>
      <label>위치 오차 기준<input name="low_accuracy_threshold_meters" type="number" min="30" max="1000" value={draft.low_accuracy_threshold_meters} onChange={(event) => setDraft({ ...draft, low_accuracy_threshold_meters: Number(event.target.value) })} required /></label>
      <label className="full">사무실 공인 IP<input name="office_ip_address" value={ip} onChange={(event) => setIp(event.target.value.trim())} placeholder="IP 확인을 사용하지 않으면 비워 두세요" /></label>
      <label className="full">변경 사유<textarea name="reason" rows={3} minLength={5} placeholder={unchanged ? "현재 설정과 같아 변경 사유가 필요하지 않습니다" : "예: 사무실 이전으로 위치와 IP 변경"} required={!unchanged} disabled={unchanged} /></label>
    </div>
    <div className="review-actions"><button type="button" className="secondary-button" onClick={() => void detectLocation()} disabled={busy || detecting !== null}>{detecting === "location" ? <LoaderCircle className="spin" /> : <LocateFixed />} 현재 위치</button><button type="button" className="secondary-button" onClick={() => void detectIp()} disabled={busy || detecting !== null}>{detecting === "ip" ? <LoaderCircle className="spin" /> : <Wifi />} 현재 IP</button><button className="primary-button compact" disabled={busy || detecting !== null || unchanged}><Check /> {unchanged ? "현재 설정과 같음" : "즉시 적용"}</button></div>
    {message && <small className="auto-detect-message">{message}</small>}
  </form>;
}

function OrganizationApprovalView({ requests, organizations, busy, onReview, onReopen }: { requests: OrganizationChangeRequest[]; organizations: Organization[]; busy: boolean; onReview: (request: OrganizationChangeRequest, decision: "approved" | "rejected") => void; onReopen: (request: OrganizationChangeRequest) => void }) {
  const labels = { workplace_location: "사업장 위치", office_ip: "사무실 IP", org_admin_account: "기관관리자 계정" };
  const [requestMonth, setRequestMonth] = useState(monthKey());
  const [statusView, setStatusView] = useState<"all" | "pending" | "approved" | "rejected">("all");
  const pending = requests.filter((request) => request.status === "pending");
  const visible = requests.filter((request) => monthKey(new Date(request.reviewed_at || request.requested_at)) === requestMonth && (statusView === "all" || request.status === statusView));
  return <section><div className="page-heading"><div><span className="kicker">최고관리자 승인</span><h1>기관 변경 요청</h1><p>위치와 IP, 기관관리자 계정 변경 요청을 월별로 검토하고 처리 완료 건도 재검토할 수 있습니다.</p></div><Badge tone="warning">대기 {pending.length}건</Badge></div><div className="toolbar-card request-admin-toolbar"><MonthPicker value={requestMonth} onChange={setRequestMonth} /><div className="request-status-tabs">{(["all", "pending", "approved", "rejected"] as const).map((status) => <button key={status} className={statusView === status ? "active" : ""} onClick={() => setStatusView(status)}>{status === "all" ? "전체" : status === "pending" ? "승인 대기" : status === "approved" ? "승인" : "반려"}</button>)}</div><Badge tone="neutral">{visible.length}건</Badge></div><div className="approval-list">{visible.map((request) => { const organization = organizations.find((item) => item.id === request.org_id); return <article className="surface-card" key={request.id}><div className="card-heading"><div><span className="kicker">{organization?.short_name || "기관"}</span><h2>{labels[request.request_type]}</h2></div><Badge tone={request.status === "pending" ? "warning" : request.status === "approved" ? "positive" : "neutral"}>{request.status === "pending" ? "승인 대기" : request.status === "approved" ? "승인" : "반려"}</Badge></div><dl className="approval-values">{Object.entries(request.proposed_values).map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{String(value ?? "")}</dd></div>)}</dl><div className="reason-box"><span>요청 사유</span><p>{request.reason}</p></div><small>요청일 {formatDate(request.requested_at)}{request.reviewed_at ? `, 처리일 ${formatDate(request.reviewed_at)}` : ""}</small>{request.status === "pending" ? <div className="review-actions"><button className="reject-button" onClick={() => onReview(request, "rejected")} disabled={busy}><X /> 반려</button><button className="approve-button" onClick={() => onReview(request, "approved")} disabled={busy}><Check /> 승인하고 적용</button></div> : <div className="review-actions"><button className="secondary-button" onClick={() => onReopen(request)} disabled={busy}><RefreshCw /> 재검토</button></div>}</article>; })}{visible.length === 0 && <EmptyState title="변경 요청이 없습니다" text="선택한 달과 상태에 맞는 변경 요청이 없습니다." />}</div></section>;
}

function TodayView({ now, record, exception, workplace, busy, locationResult, onClock }: { now: Date; record?: AttendanceRecord; exception?: AttendanceException; workplace: Workplace; busy: boolean; locationResult: LocationResult | null; onClock: (action: "clock_in" | "clock_out") => void }) {
  const status = exception ? EXCEPTION_TYPE_LABEL[exception.exception_type] || "승인 예외 근무" : record ? STATUS_LABEL[record.attendance_status] : "출근 전";
  const locationMetric = locationResult?.status === "low_accuracy" && locationResult.accuracy != null
    ? `오차 ${locationResult.accuracy}m`
    : locationResult?.distance != null ? `${locationResult.distance}m` : null;
  return <div className="today-layout"><section className="hero-panel"><div className="eyebrow"><span className="live-dot" /> 대한민국 표준시</div><div className="current-time">{new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }).format(now)}</div><h1>{formatDate(now)}</h1><div className="current-status"><span>현재 상태</span><Badge tone={exception || record?.clock_in_at && !record?.clock_out_at ? "active" : "neutral"}>{exception ? status : record?.clock_out_at ? "퇴근 완료" : record?.clock_in_at ? "근무 중" : "출근 전"}</Badge></div></section><section className="clock-panel"><div className="section-heading"><div><span className="kicker">오늘 근태</span><h2>{status}</h2></div><Clock3 /></div>{exception ? <div className="exception-today"><FileClock /><div><strong>{exception.start_date}부터 {exception.end_date}까지</strong><p>관리자가 승인한 예외 근무 기간입니다. 오늘은 출퇴근 버튼을 누르지 않아도 정상 근무로 인정됩니다.</p></div></div> : <p className="clock-guidance">실제 근무를 시작하거나 마치는 시각에 기록해 주세요. 위치는 버튼을 누르는 순간에만 확인합니다.</p>}<div className="clock-buttons"><button className="clock-button clock-in" onClick={() => onClock("clock_in")} disabled={busy || Boolean(exception) || Boolean(record?.clock_in_at)}><span><LogIn size={28} /></span><strong>{exception ? "예외 근무 적용" : record?.clock_in_at ? "출근 기록 완료" : "출근하기"}</strong><small>{formatTime(record?.clock_in_at || null)}</small></button><button className="clock-button clock-out" onClick={() => onClock("clock_out")} disabled={busy || Boolean(exception) || !record?.clock_in_at || Boolean(record?.clock_out_at)}><span><LogOut size={28} /></span><strong>{exception ? "기록 생략" : record?.clock_out_at ? "퇴근 기록 완료" : "퇴근하기"}</strong><small>{formatTime(record?.clock_out_at || null)}</small></button></div>{busy && <div className="loading-line"><LoaderCircle className="spin" /> 위치와 서버 시각을 확인하고 있습니다.</div>}</section><section className="location-card"><div className="location-icon"><MapPin /></div><div><span className="kicker">위치 확인</span><h3>{exception ? "오늘은 확인하지 않음" : locationResult ? LOCATION_LABEL[locationResult.status] : record ? LOCATION_LABEL[record.clock_out_at ? record.clock_out_location_status : record.clock_in_location_status] : "기록 버튼을 누를 때 확인"}</h3><p>{exception ? "승인된 예외 근무일에는 GPS와 공인 IP를 수집하지 않습니다." : locationResult?.message || `${workplace.workplace_name}, 허용 반경 ${workplace.allowed_radius_meters}m`}</p></div>{locationMetric && !exception && <strong>{locationMetric}</strong>}</section><section className="privacy-strip"><ShieldCheck /><div><strong>필요한 순간에만 확인합니다.</strong><p>근무 중 이동경로와 실시간 위치는 수집하지 않습니다.</p></div></section></div>;
}

function MonthPicker({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const move = (amount: number) => { const date = new Date(`${value}-01T12:00:00+09:00`); date.setMonth(date.getMonth() + amount); onChange(monthKey(date)); };
  const thisMonth = monthKey();
  return <div className="month-picker"><button onClick={() => move(-1)} aria-label="이전 달"><ChevronLeft /></button><strong>{formatMonth(value)}</strong><button onClick={() => move(1)} aria-label="다음 달"><ChevronRight /></button><button className="current-month-button" onClick={() => onChange(thisMonth)} disabled={value === thisMonth}>이번 달</button></div>;
}

function EmployeeRecords({ records, requests, exceptions, compTimeBalance: compTimeBalanceRow, annualLeaveBalance, overtimeAfterComp, month, onMonth, onCorrection }: { records: AttendanceRecord[]; requests: CorrectionRequest[]; exceptions: AttendanceException[]; compTimeBalance?: CompTimeBalance; annualLeaveBalance?: AnnualLeaveBalance; overtimeAfterComp?: MonthlyOvertimeAfterComp; month: string; onMonth: (value: string) => void; onCorrection: () => void }) {
  const compTimeBalance = compTimeBalanceRow?.available_comp_time_minutes || 0;
  return <section><div className="balance-banner"><span>연차 잔액 <strong>{annualLeaveBalance ? `${Number((annualLeaveBalance.remaining_minutes / 480).toFixed(3))}일` : "미등록"}</strong></span><span>이 달 발생분 대휴 사용 <strong>{formatMinutes(overtimeAfterComp?.comp_time_used_from_source_minutes || 0)}</strong></span><span>대휴 제외 시간외 <strong>{formatMinutes(overtimeAfterComp?.overtime_after_comp_minutes || 0)}</strong></span><span>대체휴무 적립 <strong>{formatMinutes(compTimeBalanceRow?.total_granted_comp_time_minutes || compTimeBalanceRow?.approved_overtime_minutes || 0)}</strong></span><span>사용 누계 <strong>{formatMinutes(compTimeBalanceRow?.used_comp_time_minutes || 0)}</strong></span><span>사용 가능 잔액 <strong>{formatMinutes(compTimeBalance)}</strong></span>{compTimeBalanceRow?.next_expiry_on && <span>가장 빠른 만료 <strong>{compTimeBalanceRow.next_expiry_on}</strong></span>}</div><div className="page-heading"><div><span className="kicker">나의 기록</span><h1>월별 근태기록</h1><p>일반 시간외근무와 긴급지원 인정시간을 구분해 표시합니다. 반차, 반반차, 대체휴무도 요청할 수 있습니다.</p></div><button className="secondary-button" onClick={onCorrection}><PencilLine /> 새 근태 신청</button></div><div className="toolbar-card"><MonthPicker value={month} onChange={onMonth} /><div className="summary-inline"><span>출퇴근기록 <strong>{records.length}</strong></span><span>승인 시간외 <strong>{formatMinutes(records.reduce((sum, record) => sum + regularApprovedOvertimeMinutes(record, requests), 0) + requests.filter((request) => request.request_type === "emergency_support" && request.status === "approved" && request.target_date.startsWith(month)).reduce((sum, request) => sum + (request.approved_minutes || request.calculated_minutes || 0), 0))}</strong></span><span>대체휴무 잔액 <strong>{formatMinutes(compTimeBalance)}</strong></span><span>확인 필요 <strong>{records.filter((r) => ["missing_in", "missing_out", "admin_review", "location_review"].includes(r.attendance_status)).length}</strong></span></div></div>{exceptions.length > 0 && <div className="employee-exceptions">{exceptions.map((item) => <article key={item.id}><FileClock /><div><strong>{EXCEPTION_TYPE_LABEL[item.exception_type] || "승인 예외 근무"}</strong><p>{item.start_date}부터 {item.end_date}까지</p></div><Badge tone="active">출퇴근 기록 예외</Badge></article>)}</div>}<div className="mobile-record-list">{records.map((record) => { const emergencyMinutes = approvedEmergencyMinutesForRecord(record, requests); return <article className="record-card" key={record.id}><div className="record-date"><strong>{Number(record.work_date.slice(8, 10))}</strong><span>{new Intl.DateTimeFormat("ko-KR", { weekday: "short", timeZone: "Asia/Seoul" }).format(new Date(`${record.work_date}T12:00:00+09:00`))}</span></div><div className="record-main"><div><strong>출퇴근 기록</strong><Badge tone={statusTone(record.attendance_status)}>{STATUS_LABEL[record.attendance_status]}</Badge></div><p>{formatTime(record.clock_in_at)} <ArrowRight size={14} /> {formatTime(effectiveClockOutAt(record, requests))}</p><small><LogIn size={13} /> {attendancePlaceLabel("clock_in", record.clock_in_location_status, record.clock_in_ip_matched)}</small><small><LogOut size={13} /> {attendancePlaceLabel("clock_out", record.clock_out_location_status, record.clock_out_ip_matched)}</small>{((record.recorded_overtime_minutes || 0) > 0 || emergencyMinutes > 0) && <small><Clock3 size={13} /> 일반 시간외 {formatMinutes(regularApprovedOvertimeMinutes(record, requests))}, 긴급지원 {formatMinutes(emergencyMinutes)}, 합계 {formatMinutes(totalApprovedOvertimeMinutes(record, requests))}</small>}{emergencyMinutes > 0 && <small>{emergencySupportRemark(record, requests)}</small>}{record.leave_type && record.leave_type !== "none" && <small><CalendarDays size={13} /> {record.leave_type === "half_day" ? "반차 4시간" : "반반차 2시간"}</small>}</div></article>; })}{records.length === 0 && exceptions.length === 0 && <EmptyState title="기록이 없습니다" text="선택한 달의 출퇴근 기록이 아직 없습니다." />}</div></section>;
}

function EmployeeCorrections({ requests, activeEmergencyRequest, emergencySupportEnabled, onNew, onEmergencyWork, onEditRequest }: { requests: CorrectionRequest[]; activeEmergencyRequest?: CorrectionRequest; emergencySupportEnabled: boolean; onNew: () => void; onEmergencyWork: () => void; onEditRequest: (request: CorrectionRequest) => void }) {
  const labels = { pending: "검토 대기", approved: "승인", rejected: "반려", more_info: "추가정보 필요", cancelled: "본인 취소" };
  const [requestMonth, setRequestMonth] = useState(monthKey());
  const monthlyRequests = requests.filter((request) => monthKey(new Date(request.requested_at)) === requestMonth);
  return <section><div className="page-heading"><div><span className="kicker">나의 신청</span><h1>내 신청내역</h1><p>{emergencySupportEnabled || activeEmergencyRequest ? "출퇴근 수정, 휴가, 출장, 시간외근무와 퇴근 후 긴급지원 근무를 신청할 수 있습니다." : "출퇴근 수정, 휴가, 출장과 시간외근무를 신청할 수 있습니다."}</p></div><div className="heading-actions">{(emergencySupportEnabled || activeEmergencyRequest) && <button className={activeEmergencyRequest ? "approve-button" : "secondary-button"} onClick={onEmergencyWork}><FileClock /> {activeEmergencyRequest ? "긴급지원 종료" : "긴급지원 근무"}</button>}<button className="primary-button compact" onClick={onNew}><PencilLine /> 새 신청</button></div></div><div className="toolbar-card"><MonthPicker value={requestMonth} onChange={setRequestMonth} /><Badge tone="neutral">총 {monthlyRequests.length}건</Badge></div><div className="request-list">{monthlyRequests.map((request) => <article className="request-card" key={request.id}><div className="request-top"><div><span>{requestPeriodLabel(request)}</span><h3>{REQUEST_TYPE_LABEL[request.request_type] || "근태 신청"}</h3></div><Badge tone={request.request_type === "emergency_support" && !request.end_time ? "active" : statusTone(request.status)}>{request.request_type === "emergency_support" && !request.end_time ? "진행 중" : labels[request.status]}</Badge></div><dl><div><dt>자동 계산</dt><dd>{requestValueLabel(request)}</dd></div><div><dt>사유</dt><dd>{request.reason}</dd></div>{request.reviewer_comment && <div><dt>관리자 의견</dt><dd>{request.reviewer_comment}</dd></div>}</dl><small>신청일 {formatDate(request.requested_at)} {formatTime(request.requested_at)}{request.reviewed_at ? `, ${request.reviewer_name || "관리자"} 처리 ${formatDate(request.reviewed_at)} ${formatTime(request.reviewed_at)}` : ""}</small>{["pending", "rejected", "more_info"].includes(request.status) && !(request.request_type === "emergency_support" && !request.end_time) && <div className="review-actions employee-request-actions"><button className="secondary-button" onClick={() => onEditRequest(request)}><PencilLine /> {request.status === "pending" ? "내용 수정" : "수정해서 다시 제출"}</button></div>}</article>)}{monthlyRequests.length === 0 && <EmptyState title="신청이 없습니다" text="선택한 달에 제출한 신청이 없습니다." />}</div></section>;
}

function AdminDashboard({ records, requests, profiles, onMonthly, onRequests, onConfirm }: { records: AttendanceRecord[]; requests: CorrectionRequest[]; profiles: Profile[]; onMonthly: () => void; onRequests: () => void; onConfirm: (record: AttendanceRecord) => void }) {
  const today = currentDateKey(); const todayRows = records.filter((record) => record.work_date === today);
  const cards = [
    { label: "오늘 출근", value: todayRows.filter((r) => r.clock_in_at).length, note: `전체 ${profiles.filter((p) => p.role === "employee").length}명`, icon: Users, tone: "green" },
    { label: "오늘 퇴근", value: todayRows.filter((r) => r.clock_out_at).length, note: "퇴근 기록 완료", icon: LogOut, tone: "blue" },
    { label: "위치 확인 필요", value: todayRows.filter((r) => ["location_review", "admin_review"].includes(r.attendance_status)).length, note: "미확인 기록만 표시", icon: MapPin, tone: "amber" },
    { label: "근태 신청 대기", value: requests.filter((r) => r.status === "pending").length, note: "검토가 필요합니다", icon: FileClock, tone: "rose" },
  ];
  const attention = records.filter((record) => ["late", "missing_in", "missing_out", "admin_review", "location_review"].includes(record.attendance_status)).slice(0, 6);
  return <section><div className="page-heading"><div><span className="kicker">관리자 대시보드</span><h1>오늘의 근태 현황</h1><p>{formatDate(new Date())} 기준, 확인이 필요한 기록을 먼저 보여줍니다.</p></div><button className="secondary-button" onClick={onMonthly}><CalendarDays /> 월별 근태 보기</button></div><div className="metric-grid">{cards.map((card) => <article className={`metric-card metric-${card.tone}`} key={card.label}><div><span>{card.label}</span><strong>{card.value}<small>건</small></strong><p>{card.note}</p></div><card.icon /></article>)}</div><div className="dashboard-grid"><article className="surface-card attention-card"><div className="card-heading"><div><span className="kicker">우선 확인</span><h2>확인이 필요한 기록</h2></div><button onClick={onMonthly}>전체 보기 <ArrowRight /></button></div>{attention.map((record) => <div className="attention-row" key={record.id}><div className="avatar small">{record.employee_name?.slice(0, 1)}</div><div><strong>{record.employee_name}</strong><span>{record.work_date}, {attendancePlaceLabel("clock_in", record.clock_in_location_status, record.clock_in_ip_matched)}</span></div><Badge tone={statusTone(record.attendance_status)}>{STATUS_LABEL[record.attendance_status]}</Badge>{["admin_review", "location_review", "field", "education"].includes(record.attendance_status) && <button className="attention-confirm" onClick={() => onConfirm(record)}><Check size={15} /> 확인 완료</button>}</div>)}{attention.length === 0 && <EmptyState title="확인할 기록이 없습니다" text="현재 별도 확인이 필요한 근태기록이 없습니다." />}</article><article className="surface-card quick-card"><div className="card-heading"><div><span className="kicker">빠른 업무</span><h2>관리 바로가기</h2></div></div><button onClick={onRequests}><span><PencilLine /></span><div><strong>근태 신청 검토</strong><small>{requests.filter((r) => r.status === "pending").length}건 대기 중</small></div><ArrowRight /></button><button onClick={onMonthly}><span><Download /></span><div><strong>근태자료 내보내기</strong><small>CSV, 엑셀, 인쇄</small></div><ArrowRight /></button></article></div></section>;
}

function ReportViewer({ superAdmin = false, records, summaryRecords, requests, exceptions, overtimeAfterComp, month, closing, profiles, employeeFilter, statusFilter, onMonth, onEmployee, onStatus, onCsv, onExcel, onPrint }: { superAdmin?: boolean; records: AttendanceRecord[]; summaryRecords: AttendanceRecord[]; requests: CorrectionRequest[]; exceptions: AttendanceException[]; overtimeAfterComp: MonthlyOvertimeAfterComp[]; month: string; closing: MonthClosing | null; profiles: Profile[]; employeeFilter: string; statusFilter: string; onMonth: (value: string) => void; onEmployee: (value: string) => void; onStatus: (value: string) => void; onCsv: () => void; onExcel: () => void; onPrint: () => void }) {
  const employees = profiles.filter((person) => person.role === "employee" && (employeeFilter === "all" || person.id === employeeFilter));
  return <section className="print-area">
    <div className="page-heading"><div><span className="kicker">{superAdmin ? "최고관리자 기관별 조회" : "부관리자 조회"}</span><h1>직원 근태현황</h1><p>{superAdmin ? "위에서 선택한 기관의 월별 근태만 조회합니다. 승인과 수정은 해당 기관 관리자가 처리합니다." : "전체 직원의 월별 현황과 기록을 조회하고 자료를 내려받을 수 있습니다. 승인, 수정, 삭제는 관리자만 할 수 있습니다."}</p></div><div className="heading-actions"><Badge tone={closing?.status === "closed" ? "positive" : "neutral"}>{closing?.status === "closed" ? "월 마감 완료" : "확인 중"}</Badge><div className="export-menu"><button className="primary-button compact"><Download /> 내보내기</button><div><button onClick={onCsv}>CSV</button><button onClick={onExcel}>엑셀</button><button onClick={onPrint}>인쇄, PDF</button></div></div></div></div>
    <div className="toolbar-card filters"><MonthPicker value={month} onChange={onMonth} /><label><span>직원</span><select value={employeeFilter} onChange={(event) => onEmployee(event.target.value)}><option value="all">전체 직원</option>{profiles.filter((person) => person.role === "employee").map((person) => <option value={person.id} key={person.id}>{person.name}</option>)}</select></label><label><span>상태</span><select value={statusFilter} onChange={(event) => onStatus(event.target.value)}><option value="all">전체 상태</option>{ATTENDANCE_STATUS_FILTERS.map((value) => <option value={value} key={value}>{STATUS_LABEL[value]}</option>)}</select></label></div>
    <div className="table-card monthly-summary"><div className="table-scroll"><table><thead><tr><th>직원</th><th>사무실 근무일</th><th>총 근무일</th><th>휴가 사용</th><th>승인 시간외</th><th>이 달 발생분 대휴 사용</th><th>대휴 제외 시간외</th><th>이 달 대휴 사용</th><th>출장</th><th>특별휴가</th><th>병가</th></tr></thead><tbody>{employees.map((person) => { const personRows = summaryRecords.filter((record) => record.employee_id === person.id); const overtimeNet = overtimeAfterComp.find((item) => item.employee_id === person.id); const officeDays = personRows.filter((record) => record.clock_in_at && (record.clock_in_location_status === "inside" || record.clock_in_ip_matched)).length; const exceptionTrips = exceptionDaysInMonth(exceptions, person.id, month); const recordedTrips = personRows.filter((record) => record.work_type === "business_trip" || record.attendance_status === "business_trip").length; return <tr key={person.id}><td><strong>{person.name}</strong></td><td>{officeDays}일</td><td>{personRows.filter((record) => record.clock_in_at).length + exceptionTrips}일</td><td>{leaveDays(requests, person.id, month, "annual_leave")}일</td><td>{formatMinutes(personRows.reduce((sum, record) => sum + regularApprovedOvertimeMinutes(record, requests), 0) + approvedEmergencyMinutesForEmployeeMonth(requests, person.id, month))}</td><td>{formatMinutes(overtimeNet?.comp_time_used_from_source_minutes || 0)}</td><td><strong>{formatMinutes(overtimeNet?.overtime_after_comp_minutes || 0)}</strong></td><td>{formatMinutes(compTimeMinutes(requests, person.id, month))}</td><td>{exceptionTrips + recordedTrips}일</td><td>{leaveDays(requests, person.id, month, "special_leave")}일</td><td>{leaveDays(requests, person.id, month, "sick_leave")}일</td></tr>; })}</tbody></table></div></div>
    <div className="table-card"><div className="table-scroll"><table><thead><tr><th>날짜</th><th>직원</th><th>출근</th><th>출근장소</th><th>퇴근</th><th>퇴근장소</th><th>근태상태</th><th>시간외근무</th><th>휴가</th><th>비고</th></tr></thead><tbody>{records.map((record) => <tr key={record.id}><td>{record.work_date}</td><td><strong>{record.employee_name}</strong></td><td>{formatTime(record.clock_in_at)}</td><td>{attendancePlaceLabel("clock_in", record.clock_in_location_status, record.clock_in_ip_matched)}</td><td>{formatTime(effectiveClockOutAt(record, requests))}</td><td>{attendancePlaceLabel("clock_out", record.clock_out_location_status, record.clock_out_ip_matched)}</td><td><Badge tone={statusTone(record.attendance_status)}>{STATUS_LABEL[record.attendance_status]}</Badge></td><td>{record.overtime_status === "approved" ? `${formatMinutes(record.approved_overtime_minutes || 0)} 승인${record.comp_time_eligible_minutes ? `, 대휴 ${formatMinutes(record.comp_time_eligible_minutes)} 적립` : ""}` : (record.recorded_overtime_minutes || 0) > 0 ? `${formatMinutes(record.recorded_overtime_minutes)} 검토 대기` : ""}</td><td>{attendanceLeaveLabel(record, requests)}</td><td>{[attendanceNoteWithoutEmergency(record.note), emergencySupportRemark(record, requests)].filter(Boolean).join("\n")}</td></tr>)}</tbody></table>{records.length === 0 && <EmptyState title="표시할 기록이 없습니다" text="선택한 조건에 맞는 근태기록이 없습니다." />}</div></div>
  </section>;
}

function LeaveBalanceAdmin({ profiles, annualBalances, compBalances, credits, onSaveAnnual, onDeleteAnnual, onSaveComp, onDeleteComp, onExtend }: { profiles: Profile[]; annualBalances: AnnualLeaveBalance[]; compBalances: CompTimeBalance[]; credits: CompTimeCredit[]; onSaveAnnual: (form: HTMLFormElement) => void; onDeleteAnnual: (entitlement: AnnualLeaveBalance) => void; onSaveComp: (form: HTMLFormElement) => void; onDeleteComp: (credit: CompTimeCredit) => void; onExtend: (credit: CompTimeCredit) => void }) {
  const employees = profiles.filter((person) => person.role === "employee" && person.is_active);
  const employeeName = (id: string) => profiles.find((person) => person.id === id)?.name || "미확인 직원";
  const [editingAnnual, setEditingAnnual] = useState<AnnualLeaveBalance | null>(null);
  const [editingComp, setEditingComp] = useState<CompTimeCredit | null>(null);
  const [section, setSection] = useState<"summary" | "annual" | "comp">("summary");
  return <section><div className="page-heading"><div><span className="kicker">휴가 관리</span><h1>휴가와 대휴</h1><p>직원별 잔액 확인, 연차 부여, 대체휴무 적립을 필요한 화면에서만 처리합니다.</p></div></div><div className="balance-section-tabs" aria-label="휴가 관리 구분">{([[
    "summary", "직원별 잔액"
  ], ["annual", "연차 부여"], ["comp", "대휴 적립"]] as const).map(([value, label]) => <button type="button" key={value} className={section === value ? "active" : ""} onClick={() => setSection(value)}>{label}</button>)}</div>
  {section === "summary" && <div className="table-card"><div className="section-heading"><div><span className="kicker">현재 현황</span><h2>직원별 잔액</h2></div></div><div className="table-scroll"><table><thead><tr><th>직원</th><th>연차 기간</th><th>부여</th><th>사용</th><th>잔액</th><th>대휴 적립</th><th>사용 누계</th><th>사용 가능</th><th>기한 만료</th><th>가장 빠른 만료</th></tr></thead><tbody>{employees.map((person) => { const annual = annualBalances.find((item) => item.employee_id === person.id && item.valid_from <= currentDateKey() && item.valid_to >= currentDateKey()); const comp = compBalances.find((item) => item.employee_id === person.id); return <tr key={person.id}><td><strong>{person.name}</strong></td><td>{annual ? `${annual.valid_from}부터 ${annual.valid_to}` : "미등록"}</td><td>{annual ? `${Number((annual.granted_minutes / 480).toFixed(3))}일` : ""}</td><td>{annual ? `${Number((annual.used_minutes / 480).toFixed(3))}일` : ""}</td><td>{annual ? `${Number((annual.remaining_minutes / 480).toFixed(3))}일` : ""}</td><td>{formatMinutes(comp?.total_granted_comp_time_minutes || comp?.approved_overtime_minutes || 0)}</td><td>{formatMinutes(comp?.used_comp_time_minutes || 0)}</td><td><strong>{formatMinutes(comp?.available_comp_time_minutes || 0)}</strong></td><td>{formatMinutes(comp?.expired_comp_time_minutes || 0)}</td><td>{comp?.next_expiry_on || "없음"}</td></tr>; })}</tbody></table></div></div>}
  {section === "annual" && <><form key={editingAnnual?.entitlement_id || "new-annual"} className="settings-card balance-editor" onSubmit={(event) => { event.preventDefault(); onSaveAnnual(event.currentTarget); setEditingAnnual(null); }}><input type="hidden" name="entitlement_id" value={editingAnnual?.entitlement_id || ""} /><div className="section-heading"><div><span className="kicker">연차 관리</span><h2>{editingAnnual ? "연차 부여내역 수정" : "연차 부여내역 등록"}</h2><p className="card-description">적용 기간과 부여 일수를 한 번에 입력합니다. 이월과 조정이 없으면 0을 유지하세요.</p></div></div><div className="form-grid"><label>직원<select name="employee_id" defaultValue={editingAnnual?.employee_id || ""} required><option value="">직원 선택</option>{employees.map((person) => <option key={person.id} value={person.id}>{person.name}</option>)}</select></label><label>적용 시작일<input name="valid_from" type="date" defaultValue={editingAnnual?.valid_from || ""} required /></label><label>적용 종료일<input name="valid_until" type="date" defaultValue={editingAnnual?.valid_to || ""} required /></label><label>기본 연차<input name="granted_days" type="number" min="0" step="0.125" defaultValue={editingAnnual ? editingAnnual.base_minutes / 480 : ""} placeholder="일수" required /></label><label>이월 연차<input name="carryover_days" type="number" min="0" step="0.125" defaultValue={editingAnnual ? editingAnnual.carryover_minutes / 480 : 0} /></label><label>조정 일수<input name="adjustment_days" type="number" step="0.125" defaultValue={editingAnnual ? editingAnnual.adjustment_minutes / 480 : 0} /></label><label className="full">비고<input name="note" minLength={2} defaultValue={editingAnnual?.reason || ""} placeholder="예: 2026년 연차 부여" required /></label></div><div className="review-actions"><button className="primary-button compact"><Check /> {editingAnnual ? "수정 저장" : "연차 저장"}</button>{editingAnnual && <button type="button" className="secondary-button compact" onClick={() => setEditingAnnual(null)}>수정 취소</button>}</div></form><div className="table-card"><div className="section-heading"><div><span className="kicker">등록 현황</span><h2>연차 부여내역</h2></div></div><div className="table-scroll"><table><thead><tr><th>직원</th><th>적용기간</th><th>기본</th><th>이월</th><th>조정</th><th>현재 잔액</th><th>관리</th></tr></thead><tbody>{annualBalances.map((annual) => <tr key={annual.entitlement_id}><td>{employeeName(annual.employee_id)}</td><td>{annual.valid_from}부터 {annual.valid_to}</td><td>{Number((annual.base_minutes / 480).toFixed(3))}일</td><td>{Number((annual.carryover_minutes / 480).toFixed(3))}일</td><td>{Number((annual.adjustment_minutes / 480).toFixed(3))}일</td><td>{Number((annual.remaining_minutes / 480).toFixed(3))}일</td><td><div className="table-actions"><button className="secondary-button compact" onClick={() => { setEditingAnnual(annual); window.scrollTo({ top: 0, behavior: "smooth" }); }}><PencilLine /> 수정</button><button className="reject-button compact" onClick={() => onDeleteAnnual(annual)}><Trash2 /> 삭제</button></div></td></tr>)}{annualBalances.length === 0 && <tr><td colSpan={7}>등록된 연차 부여내역이 없습니다.</td></tr>}</tbody></table></div></div></>}
  {section === "comp" && <><form key={editingComp?.id || "new-comp"} className="settings-card balance-editor" onSubmit={(event) => { event.preventDefault(); onSaveComp(event.currentTarget); setEditingComp(null); }}><input type="hidden" name="credit_id" value={editingComp?.id || ""} /><input type="hidden" name="employee_id" value={editingComp?.employee_id || ""} /><div className="section-heading"><div><span className="kicker">대휴 관리</span><h2>{editingComp ? "대체휴무 적립내역 수정" : "대체휴무 시작 잔액 등록"}</h2><p className="card-description">수기로 등록한 시작 잔액과 관리자 조정분을 수정할 수 있습니다. 시간외근무 승인으로 적립된 내역은 자동 관리됩니다.</p></div></div><div className="form-grid"><label>직원{editingComp ? <input value={editingComp.employee_name || employeeName(editingComp.employee_id)} disabled /> : <select name="employee_id" defaultValue="" required><option value="">직원 선택</option>{employees.map((person) => <option key={person.id} value={person.id}>{person.name}</option>)}</select>}</label><label>발생일<input name="source_date" type="date" defaultValue={editingComp?.source_date || ""} required /></label><label>사용기한<input name="expires_on" type="date" defaultValue={editingComp?.expires_on || ""} required /></label><label>적립 시간<input name="hours" type="number" min="0.5" step="0.5" defaultValue={editingComp ? editingComp.granted_minutes / 60 : ""} placeholder="시간" required /></label><label className="full">등록 또는 수정 사유<input name="note" minLength={5} defaultValue={editingComp?.reason || ""} placeholder="예: 이전 달 아웃리치 적립분" required /></label></div><div className="review-actions"><button className="primary-button compact"><Check /> {editingComp ? "수정 저장" : "시작 잔액 저장"}</button>{editingComp && <button type="button" className="secondary-button compact" onClick={() => setEditingComp(null)}>수정 취소</button>}</div></form><div className="table-card"><div className="section-heading"><div><span className="kicker">적립별 관리</span><h2>대체휴무 적립내역</h2></div></div><div className="table-scroll"><table><thead><tr><th>직원</th><th>발생일</th><th>적립</th><th>사용</th><th>남은 시간</th><th>사용기한</th><th>구분</th><th>관리</th></tr></thead><tbody>{credits.map((credit) => { const manual = ["opening_balance", "admin_adjustment"].includes(credit.source_type); return <tr key={credit.id}><td>{credit.employee_name || employeeName(credit.employee_id)}</td><td>{credit.source_date}</td><td>{formatMinutes(credit.granted_minutes)}</td><td>{formatMinutes(credit.used_minutes || 0)}</td><td><strong>{formatMinutes(credit.remaining_minutes)}</strong></td><td>{credit.expires_on}</td><td>{credit.source_type === "opening_balance" ? "시작 잔액" : credit.source_type === "admin_adjustment" ? "관리자 조정" : "시간외근무"}</td><td><div className="table-actions">{manual && <button className="secondary-button compact" onClick={() => { setEditingComp(credit); window.scrollTo({ top: 0, behavior: "smooth" }); }}><PencilLine /> 수정</button>}{manual && credit.used_minutes === 0 && <button className="reject-button compact" onClick={() => onDeleteComp(credit)}><Trash2 /> 삭제</button>}{credit.remaining_minutes > 0 && <button className="secondary-button compact" onClick={() => onExtend(credit)}>사용기한 변경</button>}</div></td></tr>; })}{credits.length === 0 && <tr><td colSpan={8}>대체휴무 적립내역이 없습니다.</td></tr>}</tbody></table></div></div></>}
  </section>;
}

function MonthlyAdmin({ records, summaryRecords, requests, exceptions, overtimeAfterComp, month, closing, canReopen, profiles, employeeFilter, statusFilter, onMonth, onEmployee, onStatus, onCsv, onExcel, onPrint, onClose, onReopen, onCreate, onEdit, onDelete, onOvertime, onOvertimeReopen, onConfirm, onLeave }: { records: AttendanceRecord[]; summaryRecords: AttendanceRecord[]; requests: CorrectionRequest[]; exceptions: AttendanceException[]; overtimeAfterComp: MonthlyOvertimeAfterComp[]; month: string; closing: MonthClosing | null; canReopen: boolean; profiles: Profile[]; employeeFilter: string; statusFilter: string; onMonth: (value: string) => void; onEmployee: (value: string) => void; onStatus: (value: string) => void; onCsv: () => void; onExcel: () => void; onPrint: () => void; onClose: () => void; onReopen: () => void; onCreate: () => void; onEdit: (record: AttendanceRecord) => void; onDelete: (record: AttendanceRecord) => void; onOvertime: (record: AttendanceRecord, decision: "approved" | "rejected") => void; onOvertimeReopen: (record: AttendanceRecord) => void; onConfirm: (record: AttendanceRecord) => void; onLeave: (record: AttendanceRecord) => void }) {
  const isClosed = closing?.status === "closed";
  const employees = profiles.filter((profile) => profile.role === "employee" && (employeeFilter === "all" || profile.id === employeeFilter));
  const reviewableRecords = records.filter((record) => ["admin_review", "location_review", "field", "education"].includes(record.attendance_status));
  const monthStartDate = `${month}-01`;
  const monthAfterDateValue = new Date(`${monthStartDate}T12:00:00+09:00`); monthAfterDateValue.setMonth(monthAfterDateValue.getMonth() + 1);
  const monthAfterDate = KST_DATE.format(monthAfterDateValue);
  const approvedLeaveRequests = requests.filter((request) => request.status === "approved" && ["annual_leave", "comp_time", "sick_leave", "other_leave"].includes(request.request_type) && request.target_date < monthAfterDate && (request.end_date || request.target_date) >= monthStartDate && (employeeFilter === "all" || request.employee_id === employeeFilter));
  return <section className="print-area">
    <div className="page-heading"><div><span className="kicker">월별 관리</span><h1>직원 근태현황</h1><p>출퇴근 시각과 출근장소, 퇴근장소를 확인하고 월 마감 전에 실제 시각을 수정하거나 누락된 근무를 추가할 수 있습니다.</p></div><div className="heading-actions"><button className="primary-button compact" onClick={onCreate} disabled={isClosed}><Clock3 /> 근무기록 추가</button>{isClosed ? canReopen ? <button className="secondary-button reopen-button" onClick={onReopen}><RefreshCw /> 월 마감 해제</button> : <Badge tone="warning">마감됨</Badge> : <button className="secondary-button" onClick={onClose}><Check /> 월 마감</button>}<div className="export-menu"><button className="primary-button compact"><Download /> 내보내기</button><div><button onClick={onCsv}>CSV</button><button onClick={onExcel}>엑셀</button><button onClick={onPrint}>인쇄, PDF</button></div></div></div></div>
    <div className={`month-closing-state ${isClosed ? "closed" : "open"}`}><ShieldCheck /><div><strong>{isClosed ? `${formatMonth(month)} 마감 완료` : `${formatMonth(month)} 확인 중`}</strong><p>{isClosed ? "이 달은 확정되어 일반 수정, 삭제, 근태 신청 승인이 제한됩니다. 최고관리자는 사유를 남기고 다시 열 수 있습니다." : "기록과 근태 신청을 모두 확인한 뒤 월 마감을 하면 이 달의 자료가 확정됩니다."}</p></div></div>
    <div className="toolbar-card filters"><MonthPicker value={month} onChange={onMonth} /><label><span>직원</span><select value={employeeFilter} onChange={(e) => onEmployee(e.target.value)}><option value="all">전체 직원</option>{profiles.filter((p) => p.role === "employee").map((p) => <option value={p.id} key={p.id}>{p.name}</option>)}</select></label><label><span>상태</span><select value={statusFilter} onChange={(e) => onStatus(e.target.value)}><option value="all">전체 상태</option>{ATTENDANCE_STATUS_FILTERS.map((value) => <option value={value} key={value}>{STATUS_LABEL[value]}</option>)}</select></label></div>
    {reviewableRecords.length > 0 && <div className="admin-review-panel"><div><strong>관리자 확인 필요 {reviewableRecords.length}건</strong><p>위치나 근무시간을 확인한 뒤 처리하세요. 확인 내용과 처리시각은 변경 이력에 남습니다.</p></div><div>{reviewableRecords.map((record) => <button key={record.id} type="button" onClick={() => onConfirm(record)} disabled={isClosed}><Check size={15} /> {record.work_date} {record.employee_name} 확인 완료</button>)}</div></div>}
    <div className="table-card monthly-summary"><div className="table-scroll"><table><thead><tr><th>직원</th><th>사무실 근무일</th><th>총 근무일</th><th>휴가 사용</th><th>승인 시간외</th><th>이 달 발생분 대휴 사용</th><th>대휴 제외 시간외</th><th>이 달 대휴 사용</th><th>출장</th><th>특별휴가</th><th>병가</th></tr></thead><tbody>{employees.map((person) => { const personRows = summaryRecords.filter((record) => record.employee_id === person.id); const overtimeNet = overtimeAfterComp.find((item) => item.employee_id === person.id); const officeDays = personRows.filter((record) => record.clock_in_at && (record.clock_in_location_status === "inside" || record.clock_in_ip_matched)).length; const exceptionTrips = exceptionDaysInMonth(exceptions, person.id, month); const recordedTrips = personRows.filter((record) => record.work_type === "business_trip" || record.attendance_status === "business_trip").length; return <tr key={person.id}><td><strong>{person.name}</strong></td><td>{officeDays}일</td><td>{personRows.filter((record) => record.clock_in_at).length + exceptionTrips}일</td><td>{leaveDays(requests, person.id, month, "annual_leave")}일</td><td>{formatMinutes(personRows.reduce((sum, record) => sum + (record.approved_overtime_minutes || 0), 0) + approvedEmergencyMinutesForEmployeeMonth(requests, person.id, month))}</td><td>{formatMinutes(overtimeNet?.comp_time_used_from_source_minutes || 0)}</td><td><strong>{formatMinutes(overtimeNet?.overtime_after_comp_minutes || 0)}</strong></td><td>{formatMinutes(compTimeMinutes(requests, person.id, month))}</td><td>{exceptionTrips + recordedTrips}일</td><td>{leaveDays(requests, person.id, month, "special_leave")}일</td><td>{leaveDays(requests, person.id, month, "sick_leave")}일</td></tr>; })}</tbody></table></div></div>
    {approvedLeaveRequests.length > 0 && <div className="approved-leave-panel"><strong>승인된 휴가와 대체휴무</strong><div>{approvedLeaveRequests.map((request) => <span key={request.id}><b>{request.employee_name}</b> {request.request_type === "other_leave" ? request.request_subtype || "기타 휴가" : REQUEST_TYPE_LABEL[request.request_type]} {requestPeriodLabel(request)}, {requestValueLabel(request)}</span>)}</div></div>}
    <div className="table-card"><div className="table-scroll"><table><thead><tr><th>날짜</th><th>직원</th><th>출근</th><th>출근장소</th><th>퇴근</th><th>퇴근장소</th><th>근태상태</th><th>시간외근무</th><th>휴가</th><th>수정 여부</th><th>비고</th><th>관리</th></tr></thead><tbody>{records.map((record) => { const emergencyMinutes = approvedEmergencyMinutesForRecord(record, requests); const regularRecorded = Math.max(0, (record.recorded_overtime_minutes || 0) - finishedEmergencyMinutesForRecord(record, requests)); const regularApproved = regularApprovedOvertimeMinutes(record, requests); return <tr key={record.id}><td>{record.work_date.slice(5).replace("-", ". ")}.</td><td><strong>{record.employee_name}</strong></td><td>{formatTime(record.clock_in_at)}</td><td><span className="location-cell"><LogIn size={15} />{attendancePlaceLabel("clock_in", record.clock_in_location_status, record.clock_in_ip_matched)}{record.clock_in_distance != null && !record.clock_in_ip_matched && <small>{record.clock_in_distance}m</small>}</span></td><td>{formatTime(effectiveClockOutAt(record, requests))}</td><td><span className="location-cell"><LogOut size={15} />{attendancePlaceLabel("clock_out", record.clock_out_location_status, record.clock_out_ip_matched)}{record.clock_out_distance != null && !record.clock_out_ip_matched && <small>{record.clock_out_distance}m</small>}</span></td><td><Badge tone={statusTone(record.attendance_status)}>{STATUS_LABEL[record.attendance_status]}</Badge></td><td>{regularRecorded > 0 || emergencyMinutes > 0 ? <div className="record-actions overtime-actions"><span>일반 시간외 {formatMinutes(regularRecorded)}{emergencyMinutes > 0 ? `, 긴급지원 ${formatMinutes(emergencyMinutes)}` : ""}</span>{record.overtime_status === "approved" || record.overtime_status === "rejected" ? <><Badge tone={record.overtime_status === "approved" ? "positive" : "danger"}>{record.overtime_status === "approved" ? `일반 ${formatMinutes(regularApproved)} 승인` : "일반 시간외 반려"}</Badge><button type="button" onClick={() => onOvertimeReopen(record)} disabled={isClosed}><RefreshCw size={15} /> 재검토</button></> : regularRecorded > 0 ? <><button type="button" onClick={() => onOvertime(record, "approved")} disabled={isClosed}><Check size={15} /> 승인</button><button type="button" className="danger" onClick={() => onOvertime(record, "rejected")} disabled={isClosed}><X size={15} /> 반려</button></> : <Badge tone="positive">긴급지원 승인</Badge>}</div> : ""}</td><td>{attendanceLeaveLabel(record, requests)}</td><td>{record.changed ? "있음" : "없음"}</td><td>{[attendanceNoteWithoutEmergency(record.note), emergencySupportRemark(record, requests)].filter(Boolean).join("\n")}</td><td><div className="record-actions"><button type="button" onClick={() => onLeave(record)} disabled={isClosed}><CalendarDays size={15} /> 휴가 반영</button><button type="button" onClick={() => onEdit(record)} disabled={isClosed}><PencilLine size={15} /> 수정</button><button type="button" className="danger" onClick={() => onDelete(record)} disabled={isClosed}><Trash2 size={15} /> 삭제</button></div></td></tr>; })}</tbody></table>{records.length === 0 && <EmptyState title="표시할 기록이 없습니다" text="선택한 조건에 맞는 근태기록이 없습니다." />}</div></div>
  </section>;
}

function ExceptionAdmin({ exceptions, onNew, onCancel }: { exceptions: AttendanceException[]; onNew: () => void; onCancel: (item: AttendanceException) => void }) {
  const [exceptionMonth, setExceptionMonth] = useState(monthKey());
  const firstDay = `${exceptionMonth}-01`;
  const nextMonthDate = new Date(`${firstDay}T12:00:00+09:00`);
  nextMonthDate.setMonth(nextMonthDate.getMonth() + 1);
  const nextMonth = KST_DATE.format(nextMonthDate);
  const monthly = exceptions.filter((item) => !item.cancelled_at && item.start_date < nextMonth && item.end_date >= firstDay);
  return <section><div className="page-heading"><div><span className="kicker">출퇴근 기록 예외</span><h1>예외 일정</h1><p>출장과 종일 휴가처럼 출퇴근 버튼을 누르지 않아도 되는 기간을 관리합니다. 직원 신청을 승인한 일정도 자동으로 이 목록에 표시됩니다. 시간 단위 휴가와 반차는 직원 근태현황의 휴가 반영 기능을 사용하세요.</p></div><button className="primary-button compact" onClick={onNew}><FileClock /> 예외 일정 등록</button></div><div className="toolbar-card"><MonthPicker value={exceptionMonth} onChange={setExceptionMonth} /><Badge tone="neutral">총 {monthly.length}건</Badge></div><div className="review-list exception-list">{monthly.map((item) => <article className="review-card" key={item.id}><div className="review-person"><div className="avatar">{item.employee_name?.slice(0, 1)}</div><div><strong>{item.employee_name}</strong><span>{item.start_date}부터 {item.end_date}까지</span></div><Badge tone="active">{EXCEPTION_TYPE_LABEL[item.exception_type] || "승인 예외 근무"}</Badge></div><div className="reason-box"><span>사유</span><p>{item.reason || "사유 미입력"}</p></div><small>승인자 {item.approved_by_name || "관리자"}, 승인일 {formatDate(item.approved_at)}</small><div className="review-actions"><button className="reject-button" onClick={() => onCancel(item)}><X /> 예외 취소</button></div></article>)}{monthly.length === 0 && <EmptyState title="예외 일정이 없습니다" text="선택한 달에 적용되는 출장, 종일 휴가 또는 승인 예외 일정이 없습니다." />}</div></section>;
}

function RequestAdminWorkspace({ requests, records, emergencySupportEnabled, onReview, onReopen, onEditRequest, onEditRecord, onEmergencyWork }: { requests: CorrectionRequest[]; records: AttendanceRecord[]; emergencySupportEnabled: boolean; onReview: (request: CorrectionRequest, decision: "approved" | "rejected" | "more_info") => void; onReopen: (request: CorrectionRequest) => void; onEditRequest: (request: CorrectionRequest) => void; onEditRecord: (record: AttendanceRecord) => void; onEmergencyWork: () => void }) {
  const [statusView, setStatusView] = useState<"pending" | "approved" | "rejected" | "cancelled" | "all">("pending");
  const [categoryView, setCategoryView] = useState<"all" | "correction" | "leave" | "exception" | "overtime" | "emergency">("all");
  const [requestMonth, setRequestMonth] = useState(monthKey());
  const statusLabels = { pending: "검토 대기", approved: "승인", rejected: "반려", more_info: "추가정보 필요", cancelled: "본인 취소" };
  const monthly = requests.filter((request) => monthKey(new Date(request.requested_at)) === requestMonth);
  const categoryOf = (requestType: string) => ["clock_in_at", "clock_out_at"].includes(requestType) ? "correction" : ["annual_leave", "comp_time", "sick_leave", "special_leave", "other_leave"].includes(requestType) ? "leave" : requestType === "business_trip" ? "exception" : requestType === "overtime" ? "overtime" : requestType === "emergency_support" ? "emergency" : "all";
  const categories = emergencySupportEnabled ? (["all", "correction", "leave", "exception", "overtime", "emergency"] as const) : (["all", "correction", "leave", "exception", "overtime"] as const);
  useEffect(() => { if (!emergencySupportEnabled && categoryView === "emergency") setCategoryView("all"); }, [emergencySupportEnabled, categoryView]);
  const visible = monthly.filter((request) => (statusView === "all" || (statusView === "pending" ? ["pending", "more_info"].includes(request.status) : request.status === statusView)) && (categoryView === "all" || categoryOf(request.request_type) === categoryView));
  const pendingCount = monthly.filter((request) => ["pending", "more_info"].includes(request.status)).length;
  return <section>
    <div className="page-heading"><div><span className="kicker">근태 신청</span><h1>근태 신청 관리</h1><p>{emergencySupportEnabled ? "출퇴근 수정, 휴가, 출장, 시간외근무와 퇴근 후 긴급지원 근무를 검토합니다." : "출퇴근 수정, 휴가, 출장과 시간외근무를 검토합니다. 기존 긴급지원 기록은 계속 조회할 수 있습니다."}</p></div><div className="heading-actions"><Badge tone="warning">대기 {pendingCount}건</Badge>{emergencySupportEnabled && <button className="primary-button compact" onClick={onEmergencyWork}><FileClock /> 긴급지원 근무 등록</button>}</div></div>
    <div className="toolbar-card request-admin-toolbar"><MonthPicker value={requestMonth} onChange={setRequestMonth} /><div className="request-status-tabs">{(["pending", "approved", "rejected", "cancelled", "all"] as const).map((status) => <button key={status} className={statusView === status ? "active" : ""} onClick={() => setStatusView(status)}>{status === "pending" ? "검토 대기" : status === "approved" ? "승인" : status === "rejected" ? "반려" : status === "cancelled" ? "본인 취소" : "전체"}</button>)}</div><Badge tone="neutral">{visible.length}건</Badge></div>
    <div className="request-category-tabs" aria-label="근태 신청 유형">{categories.map((category) => <button key={category} className={categoryView === category ? "active" : ""} onClick={() => setCategoryView(category)}>{category === "all" ? "전체 유형" : category === "correction" ? "출퇴근 수정" : category === "leave" ? "휴가와 대체휴무" : category === "exception" ? "출장과 예외근무" : category === "overtime" ? "일반 시간외근무" : "긴급지원"}</button>)}</div>
    <div className="review-list">{visible.map((request) => {
      const linkedRecord = request.attendance_record_id ? records.find((record) => record.id === request.attendance_record_id) : undefined;
      const isOpen = ["pending", "more_info"].includes(request.status);
      const appliedClockRequest = request.status === "approved" && ["clock_in_at", "clock_out_at"].includes(request.request_type);
      const requestedOvertime = request.request_type === "overtime" ? request.calculated_minutes || Number(request.requested_value) || 0 : 0;
      const actualOvertime = request.request_type === "overtime" ? linkedRecord?.recorded_overtime_minutes || 0 : 0;
      const overtimeLimit = Math.min(requestedOvertime, actualOvertime);
      const unfinishedEmergency = request.request_type === "emergency_support" && !request.end_time;
      const reviewStatusLabel = unfinishedEmergency && isOpen ? "지원 진행 중" : request.request_type === "overtime" && request.status === "pending" ? (linkedRecord?.clock_out_at ? "승인 대기" : "퇴근기록 대기") : statusLabels[request.status];
      return <article className="review-card" key={request.id}>
        <div className="review-person"><div className="avatar">{request.employee_name?.slice(0, 1)}</div><div><strong>{request.employee_name}</strong><span>{requestPeriodLabel(request)}, {REQUEST_TYPE_LABEL[request.request_type] || "근태 신청"}</span></div><Badge tone={unfinishedEmergency && isOpen ? "active" : statusTone(request.status)}>{reviewStatusLabel}</Badge></div>
        <div className="change-box"><div><span>{["clock_in_at", "clock_out_at"].includes(request.request_type) ? "변경 전" : "기존 기록"}</span><strong>{request.before_value.length > 60 ? "기존 기록 있음" : request.before_value}</strong></div><ArrowRight /><div><span>{["clock_in_at", "clock_out_at"].includes(request.request_type) ? "요청 값" : "신청 내용"}</span><strong>{requestValueLabel(request)}</strong></div></div>
        {request.request_type === "overtime" && <div className="summary-inline"><span>신청 <strong>{formatMinutes(requestedOvertime)}</strong></span><span>실제 인정 가능 <strong>{linkedRecord?.clock_out_at ? formatMinutes(actualOvertime) : "퇴근기록 대기"}</strong></span><span>최대 승인 <strong>{linkedRecord?.clock_out_at ? formatMinutes(overtimeLimit) : "퇴근 후 계산"}</strong></span></div>}
        <div className="reason-box"><span>신청 사유</span><p>{request.reason}</p></div>
        {request.reviewed_at && <small>{request.reviewer_name || "관리자"} 처리, {formatDate(request.reviewed_at)} {formatTime(request.reviewed_at)}{request.reviewer_comment ? `, ${request.reviewer_comment}` : ""}</small>}
        <div className="review-actions">{isOpen ? <>
          <button className="reject-button" onClick={() => onReview(request, "rejected")}><X /> 반려</button>
          <button className="secondary-button" onClick={() => onEditRequest(request)}><PencilLine /> {unfinishedEmergency ? "시작시각 수정" : request.request_type === "emergency_support" ? "실제시간 수정" : "내용 수정"}</button>
          <button className="secondary-button" onClick={() => onReview(request, "more_info")}><AlertCircle /> 추가정보 요청</button>
          <button className="approve-button" onClick={() => onReview(request, "approved")} disabled={unfinishedEmergency || request.request_type === "overtime" && overtimeLimit <= 0}><Check /> {unfinishedEmergency ? "종료 후 승인" : "승인"}</button>
        </> : appliedClockRequest ? linkedRecord && <button className="secondary-button" onClick={() => onEditRecord(linkedRecord)}><PencilLine /> 연결된 근태기록 수정</button> : request.status !== "cancelled" && (request.request_type === "emergency_support" && request.status === "approved" ? <button className="secondary-button" onClick={() => { onReopen(request); setStatusView("pending"); }}><RefreshCw /> 재검토</button> : <><button className="secondary-button" onClick={() => onEditRequest(request)}><PencilLine /> 내용 수정</button><button className="secondary-button" onClick={() => { onReopen(request); setStatusView("pending"); }}><RefreshCw /> 재검토</button></>)}</div>
      </article>;
    })}{visible.length === 0 && <EmptyState title="표시할 요청이 없습니다" text="선택한 달과 처리상태에 해당하는 요청이 없습니다." />}</div>
  </section>;
}

function RequestAdmin({ requests, records, onReview, onReopen, onEditRequest, onEditRecord, onEmergencyWork }: { requests: CorrectionRequest[]; records: AttendanceRecord[]; onReview: (request: CorrectionRequest, decision: "approved" | "rejected" | "more_info") => void; onReopen: (request: CorrectionRequest) => void; onEditRequest: (request: CorrectionRequest) => void; onEditRecord: (record: AttendanceRecord) => void; onEmergencyWork: () => void }) {
  const [statusView, setStatusView] = useState<"pending" | "approved" | "rejected" | "cancelled" | "all">("pending");
  const [categoryView, setCategoryView] = useState<"all" | "correction" | "leave" | "exception" | "overtime" | "emergency">("all");
  const [requestMonth, setRequestMonth] = useState(monthKey());
  const statusLabels = { pending: "검토 대기", approved: "승인", rejected: "반려", more_info: "추가정보 필요", cancelled: "본인 취소" };
  const monthly = requests.filter((request) => monthKey(new Date(request.requested_at)) === requestMonth);
  const categoryOf = (requestType: string) => ["clock_in_at", "clock_out_at"].includes(requestType) ? "correction" : ["annual_leave", "comp_time", "sick_leave", "special_leave", "other_leave"].includes(requestType) ? "leave" : requestType === "business_trip" ? "exception" : requestType === "overtime" ? "overtime" : requestType === "emergency_support" ? "emergency" : "all";
  const visible = monthly.filter((request) => {
    const matchesStatus = statusView === "all" || (statusView === "pending" ? ["pending", "more_info"].includes(request.status) : request.status === statusView);
    const matchesCategory = categoryView === "all" || categoryOf(request.request_type) === categoryView;
    return matchesStatus && matchesCategory;
  });
  const pendingCount = monthly.filter((request) => ["pending", "more_info"].includes(request.status)).length;
  return <section>
    <div className="page-heading"><div><span className="kicker">근태 신청</span><h1>근태 신청 관리</h1><p>출퇴근 수정, 휴가, 출장, 시간외근무와 퇴근 후 긴급지원 근무를 검토합니다.</p></div><div className="heading-actions"><Badge tone="warning">대기 {pendingCount}건</Badge><button className="primary-button compact" onClick={onEmergencyWork}><FileClock /> 긴급지원 근무 등록</button></div></div>
    <div className="toolbar-card request-admin-toolbar"><MonthPicker value={requestMonth} onChange={setRequestMonth} /><div className="request-status-tabs">{(["pending", "approved", "rejected", "all"] as const).map((status) => <button key={status} className={statusView === status ? "active" : ""} onClick={() => setStatusView(status)}>{status === "pending" ? "검토 대기" : status === "approved" ? "승인" : status === "rejected" ? "반려" : "전체"}</button>)}</div><Badge tone="neutral">{visible.length}건</Badge></div>
    <div className="request-category-tabs" aria-label="근태 신청 유형">{(["all", "correction", "leave", "exception", "overtime", "emergency"] as const).map((category) => <button key={category} className={categoryView === category ? "active" : ""} onClick={() => setCategoryView(category)}>{category === "all" ? "전체 유형" : category === "correction" ? "출퇴근 수정" : category === "leave" ? "휴가와 대체휴무" : category === "exception" ? "출장과 예외근무" : category === "overtime" ? "일반 시간외근무" : "긴급지원"}</button>)}</div>
    <div className="review-list">{visible.map((request) => {
      const linkedRecord = request.attendance_record_id ? records.find((record) => record.id === request.attendance_record_id) : undefined;
      const isOpen = ["pending", "more_info"].includes(request.status);
      const appliedClockRequest = request.status === "approved" && ["clock_in_at", "clock_out_at"].includes(request.request_type);
      const requestedOvertime = request.request_type === "overtime" ? request.calculated_minutes || Number(request.requested_value) || 0 : 0;
      const actualOvertime = request.request_type === "overtime" ? linkedRecord?.recorded_overtime_minutes || 0 : 0;
      const overtimeLimit = Math.min(requestedOvertime, actualOvertime);
      const unfinishedEmergency = request.request_type === "emergency_support" && !request.end_time;
      const reviewStatusLabel = unfinishedEmergency ? "지원 진행 중" : request.request_type === "overtime" && request.status === "pending" ? (linkedRecord?.clock_out_at ? "승인 대기" : "퇴근기록 대기") : statusLabels[request.status];
      return <article className="review-card" key={request.id}><div className="review-person"><div className="avatar">{request.employee_name?.slice(0, 1)}</div><div><strong>{request.employee_name}</strong><span>{requestPeriodLabel(request)}, {REQUEST_TYPE_LABEL[request.request_type] || "근태 신청"}</span></div><Badge tone={unfinishedEmergency ? "active" : statusTone(request.status)}>{reviewStatusLabel}</Badge></div><div className="change-box"><div><span>{["clock_in_at", "clock_out_at"].includes(request.request_type) ? "변경 전" : "기존 기록"}</span><strong>{request.before_value.length > 60 ? "기존 기록 있음" : request.before_value}</strong></div><ArrowRight /><div><span>{["clock_in_at", "clock_out_at"].includes(request.request_type) ? "요청 값" : "신청 내용"}</span><strong>{requestValueLabel(request)}</strong></div></div>{request.request_type === "overtime" && <div className="summary-inline"><span>신청 <strong>{formatMinutes(requestedOvertime)}</strong></span><span>실제 인정 가능 <strong>{linkedRecord?.clock_out_at ? formatMinutes(actualOvertime) : "퇴근기록 대기"}</strong></span><span>최대 승인 <strong>{linkedRecord?.clock_out_at ? formatMinutes(overtimeLimit) : "퇴근 후 계산"}</strong></span></div>}<div className="reason-box"><span>신청 사유</span><p>{request.reason}</p></div>{request.reviewed_at && <small>{request.reviewer_name || "관리자"} 처리, {formatDate(request.reviewed_at)} {formatTime(request.reviewed_at)}{request.reviewer_comment ? `, ${request.reviewer_comment}` : ""}</small>}<div className="review-actions">{isOpen ? <><button className="reject-button" onClick={() => onReview(request, "rejected")}><X /> 반려</button>{!unfinishedEmergency && <button className="secondary-button" onClick={() => onEditRequest(request)}><PencilLine /> 내용 수정</button>}<button className="secondary-button" onClick={() => onReview(request, "more_info")}><AlertCircle /> 추가정보 요청</button><button className="approve-button" onClick={() => onReview(request, "approved")} disabled={unfinishedEmergency || request.request_type === "overtime" && overtimeLimit <= 0}><Check /> {unfinishedEmergency ? "종료 후 승인" : "승인"}</button></> : appliedClockRequest ? linkedRecord && <button className="secondary-button" onClick={() => onEditRecord(linkedRecord)}><PencilLine /> 연결된 근태기록 수정</button> : <><button className="secondary-button" onClick={() => onEditRequest(request)}><PencilLine /> 내용 수정</button><button className="secondary-button" onClick={() => onReopen(request)}><RefreshCw /> 재검토</button></>}</div></article>;
    })}{visible.length === 0 && <EmptyState title="표시할 요청이 없습니다" text="선택한 달과 처리상태에 해당하는 요청이 없습니다." />}</div>
  </section>;
}

function AuditView({ logs, brandTitle, onRestore, superAdmin = false, selectedOrgId = "", organizations = [], organizationChanges = [] }: { logs: AuditLog[]; brandTitle: string; onRestore?: (log: AuditLog) => void; superAdmin?: boolean; selectedOrgId?: string; organizations?: Organization[]; organizationChanges?: OrganizationChangeRequest[] }) {
  const [query, setQuery] = useState("");
  const [auditMonth, setAuditMonth] = useState(monthKey());
  const [monthLogs, setMonthLogs] = useState(logs);
  const [category, setCategory] = useState<"institution" | "governance" | "independent">("institution");
  useEffect(() => {
    setMonthLogs(logs);
    if (!supabase) return;
    const from = new Date(`${auditMonth}-01T00:00:00+09:00`); const until = new Date(from); until.setMonth(until.getMonth() + 1);
    if (selectedOrgId) {
      void supabase.auth.getSession().then(async ({ data: sessionData }) => {
        const response = await fetch(`/api/admin-organization-attendance?orgId=${encodeURIComponent(selectedOrgId)}&month=${encodeURIComponent(auditMonth)}`, {
          headers: { Authorization: `Bearer ${sessionData.session?.access_token || ""}` },
          cache: "no-store",
        }).catch(() => null);
        const result = response ? await response.json().catch(() => ({})) as { audits?: AuditLog[] } : {};
        if (response?.ok && Array.isArray(result.audits)) setMonthLogs(result.audits);
      });
      return;
    }
    void supabase.from("attendance_audit_logs_view").select("*").gte("created_at", from.toISOString()).lt("created_at", until.toISOString()).order("created_at", { ascending: false }).then(({ data, error }) => { if (!error) setMonthLogs((data || []) as AuditLog[]); });
  }, [auditMonth, logs, selectedOrgId, superAdmin]);
  const sourceLogs = supabase ? monthLogs : logs;
  const governanceActions = new Set(["organization_change_approved", "organization_change_rejected", "organization_change_reopened"]);
  const superAdminOrganizationActions = new Set(["organization_created", "organization_updated", "organization_deactivated", "organization_protection_updated", "org_admin_created", "org_admin_account_updated", "org_admin_account_deleted"]);
  const independentActions = new Set(["super_admin_account_updated", "super_admin_branding_updated", "attendance_retention_purged"]);
  const auditCategory = (log: AuditLog): "institution" | "governance" | "independent" => {
    if (independentActions.has(log.action_type) || log.action_type.startsWith("super_admin_")) return "independent";
    if (log.changed_by_role === "super_admin" || governanceActions.has(log.action_type) || superAdminOrganizationActions.has(log.action_type)) return "governance";
    return "institution";
  };
  const auditCategoryLabel = (value: "institution" | "governance" | "independent") => value === "institution" ? "기관 내부 활동" : value === "governance" ? "최고관리자의 기관 처리" : "최고관리자 직접 변경";
  const categoryLogs = sourceLogs.filter((log) => {
    const resolvedCategory = auditCategory(log);
    if (resolvedCategory === "independent") return superAdmin && category === "independent";
    return resolvedCategory === category && (!selectedOrgId || log.org_id === selectedOrgId);
  });
  const filtered = categoryLogs.filter((log) => `${log.employee_name} ${log.changed_by_name} ${log.changed_field} ${log.reason}`.includes(query));
  const reviewedChanges = organizationChanges.filter((request) => request.status !== "pending" && (!selectedOrgId || request.org_id === selectedOrgId) && (request.reviewed_at || request.requested_at).startsWith(auditMonth) && `${request.request_type} ${request.reason} ${request.review_note}`.includes(query));
  const displayLogs = filtered.filter((log) => !["organization_change_approved", "organization_change_rejected"].includes(log.action_type));
  const selectedOrganizationName = organizations.find((item) => item.id === selectedOrgId)?.short_name || "해당 기관";
  const exportLogs = sourceLogs.filter((log) => {
    const resolvedCategory = auditCategory(log);
    if (resolvedCategory === "independent" && !superAdmin) return false;
    if (resolvedCategory !== "independent" && selectedOrgId && log.org_id !== selectedOrgId) return false;
    return `${log.employee_name} ${log.changed_by_name} ${log.changed_field} ${log.reason}`.includes(query);
  });
  const exportAuditCsv = () => {
    const headers = ["분류", "처리일시", "직원명", "처리유형", "변경항목", "변경 전", "변경 후", "처리자", "처리자 권한", "사유"];
    const values = exportLogs.map((log) => [auditCategoryLabel(auditCategory(log)), new Date(log.created_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }), log.employee_name || "", AUDIT_ACTION_LABEL[log.action_type] || log.action_type, auditFieldLabel(log.changed_field), readableAuditValue(log.before_value), readableAuditValue(log.after_value), log.changed_by_name || "시스템", log.changed_by_role || "", log.reason]);
    const csv = [headers, ...values].map((line) => line.map((cell) => `"${String(cell ?? "").replaceAll('"', '""')}"`).join(",")).join("\r\n");
    downloadAuditFile(new Blob(["\uFEFF" + csv], { type: "text/csv;charset=utf-8" }), `${auditMonth}_변경이력.csv`);
  };
  const exportAuditExcel = async () => {
    const ExcelJS = await import("exceljs");
    const workbook = new ExcelJS.Workbook();
    workbook.creator = brandTitle;
    const sheet = workbook.addWorksheet("변경 이력", { views: [{ state: "frozen", ySplit: 1 }] });
    sheet.columns = [
      { header: "분류", key: "category", width: 24 },
      { header: "처리일시", key: "created", width: 22 }, { header: "직원명", key: "employee", width: 12 },
      { header: "처리유형", key: "action", width: 20 }, { header: "변경항목", key: "field", width: 20 },
      { header: "변경 전", key: "before", width: 36 }, { header: "변경 후", key: "after", width: 36 },
      { header: "처리자", key: "actor", width: 12 }, { header: "처리자 권한", key: "role", width: 14 },
      { header: "사유", key: "reason", width: 34 },
    ];
    exportLogs.forEach((log) => sheet.addRow({ category: auditCategoryLabel(auditCategory(log)), created: new Date(log.created_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }), employee: log.employee_name || "", action: AUDIT_ACTION_LABEL[log.action_type] || log.action_type, field: auditFieldLabel(log.changed_field), before: readableAuditValue(log.before_value), after: readableAuditValue(log.after_value), actor: log.changed_by_name || "시스템", role: log.changed_by_role || "", reason: log.reason }));
    sheet.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
    sheet.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF173F35" } };
    sheet.autoFilter = { from: "A1", to: "J1" };
    const buffer = await workbook.xlsx.writeBuffer();
    downloadAuditFile(new Blob([buffer], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }), `${auditMonth}_변경이력.xlsx`);
  };
  const requestTypeLabel = (type: OrganizationChangeRequest["request_type"]) => type === "office_ip" ? "사무실 IP" : type === "workplace_location" ? "사업장 위치" : "기관관리자 계정";
  const totalVisible = displayLogs.length + (category === "governance" ? reviewedChanges.length : 0);
  return <section>
    <div className="page-heading"><div><span className="kicker">감사 로그</span><h1>변경 이력</h1><p>{superAdmin ? `${selectedOrganizationName} 활동과 최고관리자의 기관 처리, 최고관리자 본인 설정을 구분해 보여줍니다.` : "기관 내부 활동과 최고관리자가 이 기관에 처리한 내용을 구분해 보여줍니다."}</p></div><div className="export-menu"><button className="primary-button compact"><Download /> 내보내기</button><div><button onClick={exportAuditCsv}>CSV</button><button onClick={() => void exportAuditExcel()}>엑셀</button></div></div></div>
    <div className="request-category-tabs audit-category-tabs" aria-label="변경 이력 구분"><button className={category === "institution" ? "active" : ""} onClick={() => setCategory("institution")}>기관 내부 활동</button><button className={category === "governance" ? "active" : ""} onClick={() => setCategory("governance")}>최고관리자의 기관 처리</button>{superAdmin && <button className={category === "independent" ? "active" : ""} onClick={() => setCategory("independent")}>최고관리자 직접 변경</button>}</div>
    <div className="toolbar-card audit-toolbar"><MonthPicker value={auditMonth} onChange={setAuditMonth} /><label className="search-field"><Search /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="직원명, 변경 항목, 사유 검색" /></label><Badge tone="neutral">총 {totalVisible}건</Badge></div>
    <div className="timeline">
      {category === "governance" && reviewedChanges.map((request) => <article key={`request-${request.id}`}><div className="timeline-dot"><ShieldCheck /></div><div className="timeline-content"><div><strong>{selectedOrganizationName}</strong><Badge tone={request.status === "approved" ? "positive" : "danger"}>{request.status === "approved" ? "승인" : "반려"}</Badge><time>{formatDate(request.reviewed_at || request.requested_at)} {formatTime(request.reviewed_at || request.requested_at)}</time></div><p>{requestTypeLabel(request.request_type)} 변경 요청을 {request.status === "approved" ? "승인하고 적용했습니다." : "반려했습니다."}</p><div className="audit-values"><span>검토 대기</span><ArrowRight /><span>{request.status === "approved" ? "승인, 설정 적용" : "반려, 미적용"}</span></div><small>요청 사유 {request.reason}, 검토 메모 {request.review_note || "없음"}</small></div></article>)}
      {displayLogs.map((log) => { const directScopeName = log.action_type.startsWith("super_admin_") || log.action_type === "attendance_retention_purged" ? "최고관리자" : log.organization_name || "통합관리"; return <article key={log.id}><div className="timeline-dot"><History /></div><div className="timeline-content"><div><strong>{superAdmin && category === "independent" ? directScopeName : log.employee_name}</strong><Badge tone="neutral">{AUDIT_ACTION_LABEL[log.action_type] || log.action_type}</Badge><time>{formatDate(log.created_at)} {formatTime(log.created_at)}</time></div><p>{auditDescription(log)}</p><div className="audit-values"><span>{auditDisplayValue(log, log.before_value, "before")}</span><ArrowRight /><span>{auditDisplayValue(log, log.after_value, "after")}</span></div><small>처리자 {log.changed_by_name || "시스템"}, 사유 {log.reason || "기록 생성"}</small>{onRestore && log.action_type === "admin_delete" && log.attendance_record_id && <button className="audit-restore-button" onClick={() => onRestore(log)}><RefreshCw /> 삭제 취소, 기록 복원</button>}</div></article>; })}
      {totalVisible === 0 && <EmptyState title="변경 이력이 없습니다" text="선택한 기관, 달, 구분에 맞는 변경 이력이 없습니다." />}
    </div>
  </section>;
}

function downloadAuditFile(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  anchor.click();
  URL.revokeObjectURL(url);
}

function SettingsView({
  branding, draft, organizationDraft, setOrganizationDraft, workPolicy, setWorkPolicy, shiftTemplates, shiftAssignments, organizationChangeRequests, profiles, canResetPasswords,
  onResetPassword, onCreateEmployee, onEditEmployee, onSetEmployeeActive, onToggleReportViewer, onSave, holidayYear, holidays,
  onHolidayYear, onSyncHolidays, onAddHoliday, onEditHoliday, onRemoveHoliday, onSaveBranding, onUploadLogo, onSaveWorkPolicy, onCreateShift, onSetShiftActive, onAssignShift, onRemoveAssignment, onRequestOrganizationChange, busy,
}: {
  branding: TenantOrganization | null;
  draft: Workplace;
  organizationDraft: OrganizationSettings;
  setOrganizationDraft: (value: OrganizationSettings) => void;
  workPolicy: OrganizationWorkPolicy;
  setWorkPolicy: (value: OrganizationWorkPolicy) => void;
  shiftTemplates: WorkShiftTemplate[];
  shiftAssignments: EmployeeShiftAssignment[];
  organizationChangeRequests: OrganizationChangeRequest[];
  profiles: Profile[];
  canResetPasswords: boolean;
  onResetPassword: (profile: Profile) => void;
  onCreateEmployee: () => void;
  onEditEmployee: (profile: Profile) => void;
  onSetEmployeeActive: (profile: Profile, active: boolean) => void;
  onToggleReportViewer: (profile: Profile) => void;
  onSave: () => void;
  onSaveBranding: (form: HTMLFormElement) => void;
  onUploadLogo: (file: File) => Promise<string | null>;
  onSaveWorkPolicy: () => void;
  onCreateShift: (form: HTMLFormElement) => void;
  onSetShiftActive: (template: WorkShiftTemplate, active: boolean) => void;
  onAssignShift: (form: HTMLFormElement) => void;
  onRemoveAssignment: (assignment: EmployeeShiftAssignment) => void;
  onRequestOrganizationChange: (form: HTMLFormElement, type: OrganizationChangeRequest["request_type"]) => void;
  holidayYear: number;
  holidays: Holiday[];
  onHolidayYear: (year: number) => void;
  onSyncHolidays: () => void;
  onAddHoliday: () => void;
  onEditHoliday: (holiday: Holiday) => void;
  onRemoveHoliday: (holiday: Holiday) => void;
  busy: boolean;
}) {
  const employees = profiles.filter((person) => person.role === "employee");
  return <section>
    <div className="page-heading">
      <div><span className="kicker">기관 운영 설정</span><h1>근무와 계정 설정</h1><p>자주 바꾸는 근무 기준부터 직원 계정, 화면 꾸미기, 보호 설정 순서로 정리했습니다.</p></div>
    </div>
    <div className="settings-grid">
      <article className="surface-card full-span-card settings-priority-card">
        <div className="card-heading"><div><span className="kicker">1. 기본 근무시간</span><h2>출퇴근 자동 판정 기준</h2></div><Clock3 /></div>
        <div className="form-grid">
          <label>출근시각<input type="time" value={organizationDraft.default_start_time} onChange={(event) => setOrganizationDraft({ ...organizationDraft, default_start_time: event.target.value })} /></label>
          <label>퇴근시각<input type="time" value={organizationDraft.default_end_time} onChange={(event) => setOrganizationDraft({ ...organizationDraft, default_end_time: event.target.value })} /></label>
          <label>휴게시간<input type="number" value={organizationDraft.break_minutes} min="0" max="480" onChange={(event) => setOrganizationDraft({ ...organizationDraft, break_minutes: Number(event.target.value) })} /><small>분</small></label>
          <label>지각 유예<input type="number" value={organizationDraft.late_grace_minutes} min="0" max="180" onChange={(event) => setOrganizationDraft({ ...organizationDraft, late_grace_minutes: Number(event.target.value) })} /><small>분</small></label>
        </div>
        <div className="setting-info"><ShieldCheck /><p>평일 시간외근무는 휴게시간을 제외한 실제 근무가 8시간을 넘었는지로 계산합니다.</p></div>
        <div className="branding-actions"><button type="button" className="primary-button compact" onClick={onSave} disabled={busy}><Check /> 기본 근무시간 저장</button></div>
      </article>
      <WorkPolicySettings policy={workPolicy} setPolicy={setWorkPolicy} organizationSettings={organizationDraft} setOrganizationSettings={setOrganizationDraft} templates={shiftTemplates} assignments={shiftAssignments} profiles={profiles} onSave={() => { onSave(); onSaveWorkPolicy(); }} onCreateShift={onCreateShift} onSetShiftActive={onSetShiftActive} onAssignShift={onAssignShift} onRemoveAssignment={onRemoveAssignment} busy={busy} />
      <article className="surface-card holiday-card">
        <div className="card-heading"><div><span className="kicker">연간 일정</span><h2>공휴일 관리</h2></div><CalendarDays /></div>
        <p className="card-description">Google 공휴일을 기본으로 불러오고, 임시공휴일과 지방공휴일은 언제든 다시 불러오거나 직접 보완할 수 있습니다.</p>
        <div className="holiday-controls">
          <label>확인할 연도<input type="number" min="2026" max="2100" value={holidayYear} onChange={(event) => onHolidayYear(Number(event.target.value))} /></label>
          <button type="button" className="primary-button compact" onClick={onSyncHolidays} disabled={busy}><RefreshCw size={16} /> 선택 연도 다시 불러오기</button>
          <button type="button" className="secondary-button" onClick={onAddHoliday} disabled={busy}><CalendarDays size={16} /> 기관 휴일 직접 추가</button>
        </div>
        <div className="holiday-list">
          {holidays.map((holiday) => <div key={holiday.holiday_date}>
            <time>{holiday.holiday_date}</time><strong>{holiday.holiday_name}</strong>
            <span><button type="button" onClick={() => onEditHoliday(holiday)} disabled={busy}><PencilLine size={15} /> 수정</button><button type="button" className="danger" onClick={() => onRemoveHoliday(holiday)} disabled={busy}><Trash2 size={15} /> 취소</button></span>
          </div>)}
          {holidays.length === 0 && <p>이 연도에 저장된 휴일이 없습니다. Google 공휴일을 불러오거나 기관 휴일을 직접 추가해 주세요.</p>}
        </div>
        <div className="setting-info"><AlertCircle /><p>다시 불러오기는 기관이 직접 추가한 다른 날짜를 지우지 않습니다. 목록의 모든 휴일은 수정하거나 취소할 수 있습니다.</p></div>
      </article>
      <article className="surface-card">
        <div className="card-heading"><div><span className="kicker">조회 권한</span><h2>부관리자 지정</h2></div><ShieldCheck /></div>
        <p className="card-description">부관리자는 자신의 출퇴근 기능을 그대로 사용하면서 전체 직원 현황, 변경이력, 엑셀 자료를 조회할 수 있습니다. 승인, 수정, 삭제, 설정 권한은 없습니다.</p>
        <div className="account-list">{employees.filter((person) => person.is_active).map((person) => <div key={person.id}><div className="avatar small">{person.name.slice(0, 1)}</div><p><strong>{person.name}</strong><span>{person.employee_number}</span></p>{person.can_view_reports && <Badge tone="positive">부관리자</Badge>}<button type="button" className="secondary-button" onClick={() => onToggleReportViewer(person)} disabled={busy}><ShieldCheck size={16} /> {person.can_view_reports ? "권한 해제" : "부관리자 지정"}</button></div>)}</div>
      </article>
      {canResetPasswords && <article className="surface-card">
        <div className="card-heading"><div><span className="kicker">계정 관리</span><h2>직원 추가와 퇴사자 관리</h2></div><button type="button" className="primary-button compact" onClick={onCreateEmployee} disabled={busy}><Users size={16} /> 새 직원 추가</button></div>
        <p className="card-description">퇴사자는 로그인 목록에서 숨기고 접근을 차단하지만 기존 근태기록은 보존합니다. 필요하면 다시 활성화할 수 있습니다.</p>
        <div className="account-list">{employees.map((person) => <div key={person.id}><div className="avatar small">{person.name.slice(0, 1)}</div><p><strong>{person.name}</strong><span>{person.employee_number}</span></p><Badge tone={person.is_active ? "positive" : "neutral"}>{person.is_active ? "재직" : "퇴사"}</Badge><button type="button" className="secondary-button" onClick={() => onEditEmployee(person)} disabled={busy}><PencilLine size={16} /> 정보 수정</button>{person.is_active ? <><button type="button" className="secondary-button" onClick={() => onResetPassword(person)} disabled={busy}><KeyRound size={16} /> 비밀번호 초기화</button><button type="button" className="reject-button" onClick={() => onSetEmployeeActive(person, false)} disabled={busy}><X size={16} /> 퇴사 처리</button></> : <button type="button" className="secondary-button" onClick={() => onSetEmployeeActive(person, true)} disabled={busy}><RefreshCw size={16} /> 재활성화</button>}</div>)}</div>
        <div className="setting-info"><ShieldCheck /><p>퇴사 처리 시 부관리자 권한도 자동 해제됩니다. 직원에게 임시 비밀번호는 안전하게 전달해 주세요.</p></div>
      </article>}
      <OrganizationBrandingSettings branding={branding} onSave={onSaveBranding} onUploadLogo={onUploadLogo} busy={busy} />
      <OrganizationChangeRequestSettings workplace={draft} organizationSettings={organizationDraft} requests={organizationChangeRequests} onRequest={onRequestOrganizationChange} busy={busy} />
    </div>
  </section>;
}

function SuperAdminSettingsView({ profile, branding, onSaveAccount, onSaveBranding, onUploadLogo, onPurgeRetention, busy }: { profile: Profile; branding: OrganizationBrandingSource; onSaveAccount: (form: HTMLFormElement) => void; onSaveBranding: (form: HTMLFormElement) => void; onUploadLogo: (file: File) => Promise<string | null>; onPurgeRetention: () => void; busy: boolean }) {
  const currentYear = Number(currentDateKey().slice(0, 4));
  const deleteThroughYear = currentYear - 7;
  const keepFromYear = deleteThroughYear + 1;
  return <section>
    <div className="page-heading"><div><span className="kicker">통합관리 화면</span><h1>최고관리자 설정</h1><p>로그인 사번과 최고관리자 화면 브랜딩을 관리합니다. 기관별 설정에는 영향을 주지 않습니다.</p></div></div>
    <div className="settings-layout">
      <form className="surface-card settings-card" onSubmit={(event) => { event.preventDefault(); onSaveAccount(event.currentTarget); }}>
        <div className="card-heading"><div><span className="kicker">로그인 계정</span><h2>최고관리자 사번</h2></div><KeyRound /></div>
        <p className="card-description">여기서 정한 사번과 현재 비밀번호로 로그인할 수 있습니다. 이메일 로그인도 계속 사용할 수 있습니다.</p>
        <div className="form-grid"><label className="full">로그인 사번<input name="employee_number" defaultValue={profile.employee_number} pattern="[A-Za-z0-9-]{2,30}" required /><small>모든 기관 계정을 통틀어 중복되지 않아야 합니다.</small></label></div>
        <div className="branding-actions"><button className="primary-button compact" disabled={busy}><Check /> 최고관리자 사번 저장</button></div>
      </form>
      <OrganizationBrandingSettings scope="super_admin" branding={branding} onSave={onSaveBranding} onUploadLogo={onUploadLogo} busy={busy} />
      <article className="surface-card settings-card">
        <div className="card-heading"><div><span className="kicker">기록 보존</span><h2>5년 경과 기록 삭제</h2></div><Trash2 /></div>
        <p className="card-description">기준 연도는 매년 1월 1일 자동으로 바뀝니다. 코드를 다시 고칠 필요가 없습니다. 현재 삭제 가능한 마지막 연도는 {deleteThroughYear}년이며, 다음 해에는 {deleteThroughYear + 1}년으로 자동 변경됩니다.</p>
        <div className="setting-info"><ShieldCheck /><p>{keepFromYear}년부터 현재까지의 근태기록은 보호됩니다. 삭제 전에 {deleteThroughYear}년 12월 31일까지의 대상 건수를 보여주고 다시 확인합니다.</p></div>
        <button type="button" className="reject-button" onClick={onPurgeRetention} disabled={busy}><Trash2 size={16} /> 5년 경과 기록 삭제</button>
      </article>
    </div>
  </section>;
}

function RetentionCleanupModal({ preview, busy, onClose, onConfirm }: { preview: { deleteThroughYear: number; keepFromYear: number; attendanceRecords: number; correctionRequests: number; attendanceExceptions: number; auditLogs: number }; busy: boolean; onClose: () => void; onConfirm: () => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="retention-cleanup-title"><div className="modal correction-modal"><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">기록 보존기간 확인</span><h2 id="retention-cleanup-title">{preview.deleteThroughYear}년 12월 31일까지 삭제됩니다</h2><p>삭제한 기록은 되돌릴 수 없습니다. {preview.keepFromYear}년 1월 1일부터 현재까지의 기록은 그대로 유지됩니다.</p><div className="summary-inline"><span>근태기록 <strong>{preview.attendanceRecords}건</strong></span><span>신청 <strong>{preview.correctionRequests}건</strong></span><span>예외일정 <strong>{preview.attendanceExceptions}건</strong></span><span>변경이력 <strong>{preview.auditLogs}건</strong></span></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={busy}>취소</button><button type="button" className="reject-button" onClick={onConfirm} disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Trash2 />} 확인하고 삭제</button></div></div></div>;
}

function OrganizationBrandingSettings({ scope = "organization", branding, onSave, onUploadLogo, busy }: { scope?: "organization" | "super_admin"; branding: OrganizationBrandingSource | null; onSave: (form: HTMLFormElement) => void; onUploadLogo: (file: File) => Promise<string | null>; busy: boolean }) {
  const resolved = organizationBranding(branding);
  const [draft, setDraft] = useState({
    title: branding?.brand_title || resolved.title,
    mark: branding?.brand_mark || resolved.mark,
    description: branding?.brand_description || resolved.description,
    subtitle: branding?.brand_subtitle || resolved.subtitle,
    logoUrl: branding?.brand_logo_url || "",
    primaryColor: resolved.primaryColor,
    accentColor: resolved.accentColor,
  });
  const [uploading, setUploading] = useState(false);

  useEffect(() => {
    const next = organizationBranding(branding);
    setDraft({
      title: branding?.brand_title || next.title,
      mark: branding?.brand_mark || next.mark,
      description: branding?.brand_description || next.description,
      subtitle: branding?.brand_subtitle || next.subtitle,
      logoUrl: branding?.brand_logo_url || "",
      primaryColor: next.primaryColor,
      accentColor: next.accentColor,
    });
  }, [branding]);

  const preview = organizationBranding({
    ...branding,
    brand_title: draft.title,
    brand_mark: draft.mark,
    brand_description: draft.description,
    brand_subtitle: draft.subtitle,
    brand_logo_url: draft.logoUrl,
    brand_primary_color: draft.primaryColor,
    brand_accent_color: draft.accentColor,
  });

  const uploadLogo = async (file?: File) => {
    if (!file) return;
    setUploading(true);
    const logoUrl = await onUploadLogo(file);
    setUploading(false);
    if (logoUrl) setDraft((current) => ({ ...current, logoUrl }));
  };

  return <form className="surface-card full-span-card" onSubmit={(event) => { event.preventDefault(); onSave(event.currentTarget); }}>
    <div className="card-heading"><div><span className="kicker">{scope === "super_admin" ? "최고관리자 설정" : "기관관리자 설정"}</span><h2>{scope === "super_admin" ? "내 통합관리 화면과 로고" : "기관 화면과 로고"}</h2></div><div className="branding-preview" style={{ background: preview.primaryColor, color: readableTextColor(preview.primaryColor) }}>{preview.logoUrl ? <img src={preview.logoUrl} alt="로고 미리보기" /> : preview.mark}</div></div>
    <p className="card-description">{scope === "super_admin" ? "이 설정은 최고관리자 계정 화면에만 적용되며 각 기관의 제목, 로고와 색상은 바꾸지 않습니다." : "기관관리자가 자기 기관의 제목, 설명, 로고와 색상을 직접 바꿀 수 있습니다. 기관 공식명, 도메인과 기관 사용 중지는 최고관리자가 관리합니다."}</p>
    <div className="form-grid">
      <label>화면 제목<input name="brand_title" value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} required /></label>
      <label>짧은 표시<input name="brand_mark" value={draft.mark} onChange={(event) => setDraft({ ...draft, mark: event.target.value })} maxLength={2} /></label>
      <label className="full">화면 설명<input name="brand_description" value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label>
      <label className="full">보조 문구<input name="brand_subtitle" value={draft.subtitle} onChange={(event) => setDraft({ ...draft, subtitle: event.target.value })} /></label>
      <label className="full logo-upload-field">로고 파일<input type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => void uploadLogo(event.target.files?.[0])} disabled={busy || uploading} /><small>PNG, JPG, WEBP 파일을 2MB 이하로 올리면 기관별 저장공간에 보관됩니다.</small></label>
      <input name="brand_logo_url" type="hidden" value={draft.logoUrl} readOnly />
      <label>대표 색상<input name="brand_primary_color" type="color" value={draft.primaryColor} onChange={(event) => setDraft({ ...draft, primaryColor: event.target.value })} /></label>
      <label>강조 색상<input name="brand_accent_color" type="color" value={draft.accentColor} onChange={(event) => setDraft({ ...draft, accentColor: event.target.value })} /></label>
    </div>
    <div className="setting-info"><ShieldCheck /><p>색상은 메뉴 선택 상태, 버튼, 강조 화면에도 함께 적용됩니다. 로고는 주소를 입력하지 않고 파일만 올리면 됩니다.</p></div>
    <div className="branding-actions">
      <button type="button" className="secondary-button" onClick={() => setDraft({ ...draft, primaryColor: DEFAULT_PRIMARY_COLOR, accentColor: DEFAULT_ACCENT_COLOR })} disabled={busy || uploading}><RefreshCw /> 기본 색상으로 되돌리기</button>
      {draft.logoUrl && <button type="button" className="secondary-button" onClick={() => setDraft({ ...draft, logoUrl: "" })} disabled={busy || uploading}><X /> 로고 사용 안 함</button>}
      <button className="primary-button compact" disabled={busy || uploading}>{uploading ? <LoaderCircle className="spin" /> : <Check />} {scope === "super_admin" ? "내 화면 저장" : "기관 화면 저장"}</button>
    </div>
  </form>;
}

function OrganizationChangeRequestSettings({ workplace, organizationSettings, requests, onRequest, busy }: { workplace: Workplace; organizationSettings: OrganizationSettings; requests: OrganizationChangeRequest[]; onRequest: (form: HTMLFormElement, type: OrganizationChangeRequest["request_type"]) => void; busy: boolean }) {
  const pending = requests.filter((request) => request.status === "pending");
  const [locationProposal, setLocationProposal] = useState({
    workplace_name: workplace.workplace_name,
    latitude: workplace.latitude,
    longitude: workplace.longitude,
  });
  const [ipProposal, setIpProposal] = useState(organizationSettings.office_ip_address);
  const [detectingLocation, setDetectingLocation] = useState(false);
  const [detectingIp, setDetectingIp] = useState(false);
  const [locationMessage, setLocationMessage] = useState("");
  const [ipMessage, setIpMessage] = useState("");
  const locationUnchanged = locationProposal.workplace_name.trim() === workplace.workplace_name.trim() && locationProposal.latitude === workplace.latitude && locationProposal.longitude === workplace.longitude;
  const ipUnchanged = normalizeIpAddress(ipProposal) === normalizeIpAddress(organizationSettings.office_ip_address);

  useEffect(() => {
    setLocationProposal({ workplace_name: workplace.workplace_name, latitude: workplace.latitude, longitude: workplace.longitude });
    setLocationMessage("");
  }, [workplace.workplace_name, workplace.latitude, workplace.longitude]);

  useEffect(() => {
    setIpProposal(organizationSettings.office_ip_address);
    setIpMessage("");
  }, [organizationSettings.office_ip_address]);

  const detectCurrentLocationProposal = async () => {
    setDetectingLocation(true);
    setLocationMessage("현재 위치를 확인하고 있습니다.");
    const location = await requestCurrentLocation(workplace);
    setDetectingLocation(false);
    if (location.latitude == null || location.longitude == null) {
      setLocationMessage(location.message);
      return;
    }
    setLocationProposal((current) => ({
      ...current,
      latitude: Number(location.latitude?.toFixed(6)),
      longitude: Number(location.longitude?.toFixed(6)),
    }));
    setLocationMessage(location.accuracy == null
      ? "현재 위치를 입력했습니다. 변경 사유를 적고 승인을 요청해 주세요."
      : `현재 위치를 입력했습니다. 측정 오차는 약 ${Math.round(location.accuracy)}m입니다.`);
  };

  const detectCurrentIpProposal = async () => {
    setDetectingIp(true);
    setIpMessage("현재 공인 IP를 확인하고 있습니다.");
    const ip = await fetchClientIp();
    setDetectingIp(false);
    if (!ip) {
      setIpMessage("현재 공인 IP를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.");
      return;
    }
    setIpProposal(ip);
    setIpMessage(normalizeIpAddress(ip) === normalizeIpAddress(organizationSettings.office_ip_address)
      ? `현재 공인 IP ${ip}는 이미 등록된 사무실 IP입니다. 변경 요청이 필요하지 않습니다.`
      : `현재 공인 IP ${ip}를 입력했습니다. 변경 사유를 적고 승인을 요청해 주세요.`);
  };

  return <article className="surface-card full-span-card">
    <div className="card-heading"><div><span className="kicker">최고관리자 승인 필요</span><h2>보호 설정 변경 요청</h2></div><ShieldCheck /></div>
    <p className="card-description">현재 위치와 IP를 자동으로 입력할 수 있습니다. 입력한 값은 바로 적용되지 않고 최고관리자의 승인을 받은 뒤 적용됩니다.</p>
    <div className="protected-change-grid">
      <form onSubmit={(event) => { event.preventDefault(); onRequest(event.currentTarget, "workplace_location"); }}>
        <h3>사업장 위치</h3>
        <button type="button" className="secondary-button compact" onClick={() => void detectCurrentLocationProposal()} disabled={busy || detectingLocation}>{detectingLocation ? <LoaderCircle className="spin" /> : <LocateFixed />} 현재 위치 자동입력</button>
        <label>사업장명<input name="workplace_name" value={locationProposal.workplace_name} onChange={(event) => setLocationProposal({ ...locationProposal, workplace_name: event.target.value })} required /></label>
        <div className="form-grid">
          <label>위도<input name="latitude" type="number" step="0.000001" value={locationProposal.latitude} onChange={(event) => setLocationProposal({ ...locationProposal, latitude: Number(event.target.value) })} required /></label>
          <label>경도<input name="longitude" type="number" step="0.000001" value={locationProposal.longitude} onChange={(event) => setLocationProposal({ ...locationProposal, longitude: Number(event.target.value) })} required /></label>
          <input name="allowed_radius_meters" type="hidden" value={workplace.allowed_radius_meters} readOnly />
          <input name="low_accuracy_threshold_meters" type="hidden" value={workplace.low_accuracy_threshold_meters} readOnly />
        </div>
        {locationMessage && <small className="auto-detect-message">{locationMessage}</small>}
        <textarea name="reason" rows={2} minLength={5} placeholder={locationUnchanged ? "현재 설정과 같아 사유가 필요하지 않습니다" : "변경 사유"} required={!locationUnchanged} disabled={locationUnchanged} />
        <button className="primary-button compact" disabled={busy || detectingLocation || locationUnchanged}>{locationUnchanged ? "현재 위치와 같음" : "위치 변경 승인 요청"}</button>
      </form>
      <form onSubmit={(event) => { event.preventDefault(); onRequest(event.currentTarget, "office_ip"); }}>
        <h3>사무실 IP</h3>
        <button type="button" className="secondary-button compact" onClick={() => void detectCurrentIpProposal()} disabled={busy || detectingIp}>{detectingIp ? <LoaderCircle className="spin" /> : <Wifi />} 현재 IP 자동입력</button>
        <label>공인 IP<input name="office_ip_address" value={ipProposal} onChange={(event) => setIpProposal(event.target.value)} required /></label>
        {ipMessage && <small className="auto-detect-message">{ipMessage}</small>}
        <textarea name="reason" rows={2} minLength={5} placeholder={ipUnchanged ? "현재 설정과 같아 사유가 필요하지 않습니다" : "변경 사유"} required={!ipUnchanged} disabled={ipUnchanged} />
        <button className="primary-button compact" disabled={busy || detectingIp || ipUnchanged}>{ipUnchanged ? "현재 IP와 같음" : "IP 변경 승인 요청"}</button>
      </form>
      <form onSubmit={(event) => { event.preventDefault(); onRequest(event.currentTarget, "org_admin_account"); }}>
        <h3>기관관리자 교체</h3>
        <input name="name" placeholder="새 관리자 이름" required />
        <input name="employee_number" placeholder="새 관리자 사번" required />
        <textarea name="reason" rows={2} minLength={5} placeholder="교체 사유" required />
        <button className="primary-button compact" disabled={busy}>관리자 교체 승인 요청</button>
      </form>
    </div>
    {pending.length > 0 && <div className="setting-info"><AlertCircle /><p>현재 최고관리자 승인 대기 {pending.length}건이 있습니다.</p></div>}
  </article>;
}

function WorkPolicySettings({ policy, setPolicy, organizationSettings, setOrganizationSettings, templates, assignments, profiles, onSave, onCreateShift, onSetShiftActive, onAssignShift, onRemoveAssignment, busy }: {
  policy: OrganizationWorkPolicy;
  setPolicy: (value: OrganizationWorkPolicy) => void;
  organizationSettings: OrganizationSettings;
  setOrganizationSettings: (value: OrganizationSettings) => void;
  templates: WorkShiftTemplate[];
  assignments: EmployeeShiftAssignment[];
  profiles: Profile[];
  onSave: () => void;
  onCreateShift: (form: HTMLFormElement) => void;
  onSetShiftActive: (template: WorkShiftTemplate, active: boolean) => void;
  onAssignShift: (form: HTMLFormElement) => void;
  onRemoveAssignment: (assignment: EmployeeShiftAssignment) => void;
  busy: boolean;
}) {
  const employees = profiles.filter((person) => person.role === "employee" && person.is_active);
  const activeTemplates = templates.filter((template) => template.is_active);
  const usesShiftSchedule = policy.attendance_mode === "shift";
  return <>
    <article className="surface-card full-span-card">
      <div className="card-heading"><div><span className="kicker">기관별 근무조건</span><h2>근무방식과 날짜 판정</h2></div><Clock3 /></div>
      <div className="form-grid policy-basic-grid">
        <label>근무방식<select value={policy.attendance_mode} onChange={(event) => setPolicy({ ...policy, attendance_mode: event.target.value as OrganizationWorkPolicy["attendance_mode"] })}><option value="fixed">고정 근무</option><option value="flexible">유연 근무</option><option value="shift">교대와 당직 근무</option></select></label>
        <label>근무일 경계시각<input type="time" value={policy.work_date_boundary_time} onChange={(event) => setPolicy({ ...policy, work_date_boundary_time: event.target.value })} /><small>이 시각 전 퇴근은 전날 근무로 처리</small></label>
        <label>연속 근무 허용시간<input type="number" min={8} max={48} value={policy.max_open_shift_hours} onChange={(event) => setPolicy({ ...policy, max_open_shift_hours: Number(event.target.value) })} /><small>시간</small></label>
        <label>시간외 반올림<select value={policy.overtime_rounding_minutes} onChange={(event) => setPolicy({ ...policy, overtime_rounding_minutes: Number(event.target.value) as OrganizationWorkPolicy["overtime_rounding_minutes"] })}>{[1, 5, 10, 15, 30, 60].map((minute) => <option key={minute} value={minute}>{minute}분</option>)}</select></label>
      </div>
      <div className="policy-toggle-grid">
        <div className="policy-toggle-card"><label className="checkbox-setting"><input type="checkbox" checked={policy.holiday_work_counts_as_overtime} onChange={(event) => setPolicy({ ...policy, holiday_work_counts_as_overtime: event.target.checked })} /> 휴일근무를 시간외근무로 인정</label><p>주말과 기관 휴일의 실제 근무 전체를 시간외근무로 계산하고, 위 반올림 단위를 적용합니다.</p></div>
        <div className="policy-toggle-card"><label className="checkbox-setting"><input type="checkbox" checked={organizationSettings.emergency_support_enabled} onChange={(event) => setOrganizationSettings({ ...organizationSettings, emergency_support_enabled: event.target.checked })} /> 긴급지원 근무 사용</label><p>사용하는 기관에만 직원 신청과 관리자 등록 기능을 표시합니다. 꺼도 기존 기록은 보존됩니다.</p></div>
        <div className="policy-toggle-card"><label className="checkbox-setting"><input type="checkbox" checked={policy.require_location} onChange={(event) => setPolicy({ ...policy, require_location: event.target.checked })} /> 출퇴근 위치 확인 사용</label><p>출퇴근 순간의 위치만 확인합니다. 이동경로를 계속 추적하지 않습니다.</p></div>
        <div className="policy-toggle-card"><label className="checkbox-setting"><input type="checkbox" checked={policy.require_office_ip} onChange={(event) => setPolicy({ ...policy, require_office_ip: event.target.checked })} /> 사무실 IP만 허용</label><p>일반 기관은 끄는 것을 권장합니다. 켜면 사무실 IP가 아닌 기록은 외부 기록으로 처리합니다.</p></div>
      </div>
      <div className="setting-info"><ShieldCheck /><p>{usesShiftSchedule ? "교대와 당직 근무에서는 아래에서 근무조와 직원별 근무표를 관리합니다. 야간 퇴근은 출근한 날짜의 기록에 연결됩니다." : policy.attendance_mode === "fixed" ? "고정 근무에서는 기관의 기본 근무시간을 사용하므로 근무조와 근무표를 따로 만들지 않습니다." : "유연 근무에서는 기관 기준시간으로 근태를 판정하며 근무조와 근무표를 따로 만들지 않습니다."}</p></div>
      <div className="settings-save-actions"><button type="button" className="primary-button compact" onClick={onSave} disabled={busy}><Check /> 기관별 근무조건 저장</button></div>
    </article>
    {usesShiftSchedule && <>
    <form className="surface-card" onSubmit={(event) => { event.preventDefault(); onCreateShift(event.currentTarget); }}>
      <div className="card-heading"><div><span className="kicker">교대와 야간당직</span><h2>근무조 만들기</h2></div><FileClock /></div>
      <div className="form-grid"><label>근무조 이름<input name="shift_name" placeholder="예: 야간당직" required /></label><label>근무조 코드<input name="shift_code" pattern="[A-Za-z0-9_-]{1,20}" placeholder="예: NIGHT" required /></label><label>시작시각<input name="start_time" type="time" defaultValue="18:00" required /></label><label>종료시각<input name="end_time" type="time" defaultValue="09:00" required /></label><label>휴게시간<input name="break_minutes" type="number" min={0} max={480} defaultValue={60} /><small>분</small></label><label>지각 유예<input name="late_grace_minutes" type="number" min={0} max={180} defaultValue={0} /><small>분</small></label><label className="checkbox-setting full"><input name="crosses_midnight" type="checkbox" defaultChecked /> 다음 날 종료되는 야간 근무</label></div>
      <button className="primary-button compact" disabled={busy}><Check /> 근무조 만들기</button>
      <div className="shift-template-list">{templates.map((template) => <div key={template.id}><p><strong>{template.shift_name}</strong><span>{template.start_time}부터 {template.end_time}까지{template.crosses_midnight ? ", 다음 날 퇴근" : ""}</span></p><Badge tone={template.is_active ? "positive" : "neutral"}>{template.is_active ? "사용 중" : "중지"}</Badge><button type="button" className="secondary-button" onClick={() => onSetShiftActive(template, !template.is_active)} disabled={busy}>{template.is_active ? "중지" : "다시 사용"}</button></div>)}</div>
    </form>
    <form className="surface-card" onSubmit={(event) => { event.preventDefault(); onAssignShift(event.currentTarget); }}>
      <div className="card-heading"><div><span className="kicker">근무표</span><h2>직원 근무조 배정</h2></div><CalendarDays /></div>
      <div className="form-grid"><label>직원<select name="employee_id" required><option value="">직원 선택</option>{employees.map((person) => <option key={person.id} value={person.id}>{person.name}</option>)}</select></label><label>근무일<input name="work_date" type="date" required /></label><label className="full">근무조<select name="shift_template_id" required><option value="">근무조 선택</option>{activeTemplates.map((template) => <option key={template.id} value={template.id}>{template.shift_name}, {template.start_time}부터 {template.end_time}</option>)}</select></label><label className="full">메모<input name="note" placeholder="선택 입력" /></label></div>
      <button className="primary-button compact" disabled={busy || employees.length === 0 || activeTemplates.length === 0}><Check /> 근무조 배정</button>
      <div className="shift-assignment-list">{assignments.map((assignment) => { const employee = profiles.find((person) => person.id === assignment.employee_id); const template = templates.find((item) => item.id === assignment.shift_template_id); return <div key={assignment.id}><time>{assignment.work_date}</time><p><strong>{employee?.name || "직원"}</strong><span>{template?.shift_name || "근무조"}</span></p><button type="button" className="reject-button" onClick={() => onRemoveAssignment(assignment)} disabled={busy}><X size={15} /> 배정 취소</button></div>; })}{assignments.length === 0 && <p>선택한 달에 배정된 근무조가 없습니다.</p>}</div>
    </form>
    </>}
  </>;
}
function EmployeeCreateModal({ busy, onClose, onSubmit }: { busy: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="employee-create-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose}><X /></button><div className="modal-icon"><Users /></div><span className="kicker">기관 관리자 계정 관리</span><h2 id="employee-create-title">새 직원 추가</h2><p>새 직원은 현재 관리자의 기관으로 등록되며 사번은 입사연도 뒤 2자리와 전체 기관 공통 순번 4자리로 자동 발급됩니다.</p><div className="form-grid"><label className="full">이름<input name="name" minLength={2} maxLength={30} required /></label><label className="full">부서<input name="department" maxLength={50} placeholder="예: 상담지원팀" /></label><label className="full">관리자 현재 비밀번호<input name="admin_password" type="password" autoComplete="current-password" required /></label><label>직원 임시 비밀번호<input name="password" type="password" minLength={6} required /></label><label>임시 비밀번호 확인<input name="confirm_password" type="password" minLength={6} required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Users />} 직원 계정 만들기</button></div></form></div>;
}

function EmployeeEditModal({ profile, busy, onClose, onSubmit }: { profile: Profile; busy: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="employee-edit-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose}><X /></button><div className="modal-icon"><PencilLine /></div><span className="kicker">직원 계정 관리</span><h2 id="employee-edit-title">{profile.name}님 정보 수정</h2><p>이름, 부서, 사번을 바꾸고 필요하면 로그인용 임시 비밀번호도 같이 설정할 수 있습니다. 기존 근태기록은 그대로 유지됩니다.</p><div className="form-grid"><label>이름<input name="name" defaultValue={profile.name} minLength={2} maxLength={30} required /></label><label>사번<input name="employee_number" defaultValue={profile.employee_number} pattern="[A-Za-z0-9-]{2,30}" required /></label><label className="full">부서<input name="department" defaultValue={profile.department || ""} maxLength={50} /></label><label>새 임시 비밀번호, 선택<input name="password" type="password" minLength={6} autoComplete="new-password" /></label><label>임시 비밀번호 확인<input name="confirm_password" type="password" minLength={6} autoComplete="new-password" /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 직원 정보 저장</button></div></form></div>;
}

function IosInstallGuide({ onClose }: { onClose: () => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="ios-install-title"><div className="modal consent-modal ios-install-modal"><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><div className="modal-icon"><Download /></div><span className="kicker">iPhone 앱 설치</span><h2 id="ios-install-title">홈 화면에 추가해 주세요</h2><p>iPhone에서는 웹사이트가 설치창을 직접 띄울 수 없습니다. 브라우저의 공유 메뉴에서 아래 순서로 설치합니다.</p><ol><li><strong>1</strong><span>화면 아래 또는 위의 <b>공유</b> 버튼을 누릅니다.</span></li><li><strong>2</strong><span><b>홈 화면에 추가</b>를 선택합니다.</span></li><li><strong>3</strong><span><b>웹 앱으로 열기</b>를 켜고 <b>추가</b>를 누릅니다.</span></li></ol><div className="setting-info"><AlertCircle /><p>iOS Chrome의 공유 메뉴에 홈 화면 추가가 없다면 같은 주소를 Safari로 열어 진행해 주세요.</p></div><div className="modal-actions"><button type="button" className="primary-button compact" onClick={onClose}><Check /> 확인</button></div></div></div>;
}

function PasswordChangeModal({ recovery, privileged, busy, onClose, onSubmit }: { recovery: boolean; privileged: boolean; busy: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const minimumLength = privileged ? 8 : 6;
  const passwordRule = privileged
    ? "8자 이상으로 영문, 숫자, 특수문자를 각각 1개 이상 포함해 주세요."
    : "6자 이상으로 설정해 주세요.";
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="password-change-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기" disabled={recovery}><X /></button><div className="modal-icon"><KeyRound /></div><span className="kicker">내 계정</span><h2 id="password-change-title">{recovery ? "새 비밀번호 설정" : "비밀번호 변경"}</h2><p>{recovery ? "재설정 안내를 받은 계정의 새 비밀번호를 입력해 주세요." : "현재 비밀번호를 확인한 뒤 새 비밀번호로 변경합니다."}</p><div className="form-grid">{!recovery && <label className="full">현재 비밀번호<input name="current_password" type="password" autoComplete="current-password" required /></label>}<label className="full">새 비밀번호<input name="new_password" type="password" autoComplete="new-password" minLength={minimumLength} required /><small>{passwordRule}</small></label><label className="full">새 비밀번호 확인<input name="confirm_password" type="password" autoComplete="new-password" minLength={minimumLength} required /></label></div><div className="modal-actions">{!recovery && <button type="button" className="secondary-button" onClick={onClose}>취소</button>}<button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 비밀번호 저장</button></div></form></div>;
}

function AdminResetPasswordModal({ profile, busy, onClose, onSubmit }: { profile: Profile; busy: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="admin-reset-password-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><div className="modal-icon"><KeyRound /></div><span className="kicker">기관 관리자 계정 관리</span><h2 id="admin-reset-password-title">{profile.name}님 비밀번호 초기화</h2><p>계정과 기존 근태기록은 유지하고 임시 비밀번호만 새로 설정합니다.</p><div className="form-grid"><label className="full">관리자 현재 비밀번호<input name="admin_password" type="password" autoComplete="current-password" required /><small>권한 확인을 위해 기관 관리자 비밀번호를 다시 입력합니다.</small></label><label className="full">직원 임시 비밀번호<input name="new_password" type="password" autoComplete="new-password" minLength={6} required /><small>6자 이상으로 설정해 주세요.</small></label><label className="full">임시 비밀번호 확인<input name="confirm_password" type="password" autoComplete="new-password" minLength={6} required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <KeyRound />} 임시 비밀번호 설정</button></div></form></div>;
}

function ConsentModal({ onCancel, onAgree }: { onCancel: () => void; onAgree: () => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="consent-title"><div className="modal consent-modal"><button className="modal-close" onClick={onCancel} aria-label="닫기"><X /></button><div className="modal-icon"><LocateFixed /></div><span className="kicker">위치와 네트워크 정보 수집 안내</span><h2 id="consent-title">필요한 순간에만 확인합니다.</h2><p>출퇴근 사실과 근무 장소 확인을 위해 출근 또는 퇴근 기록 버튼을 누르는 시점의 위치정보와 공인 IP 주소를 수집합니다. 이 정보는 버튼을 누르는 순간에만 확인하며, 근무시간 중 이동경로나 실시간 위치를 추적하지 않습니다. 수집한 정보는 근태관리와 관련된 확인 목적으로만 이용합니다.</p><ul><li><Check /> 버튼을 누른 순간의 위치와 공인 IP만 확인</li><li><Check /> 실시간 이동경로와 백그라운드 추적 없음</li><li><Check /> GPS가 부정확하면 사무실 고정 IP로 보완</li></ul><div className="modal-actions"><button className="secondary-button" onClick={onCancel}>취소</button><button className="primary-button compact" onClick={onAgree}><ShieldCheck /> 안내를 확인하고 동의</button></div></div></div>;
}

function AttendanceEditModal({ record, onClose, onSubmit }: { record: AttendanceRecord; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="attendance-edit-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">관리자 직접 수정</span><h2 id="attendance-edit-title">{record.employee_name}님의 {record.work_date} 기록</h2><p>출퇴근 시각을 저장하면 실제 기록에 반영되며, 변경 전후 값과 사유는 변경 이력에 남습니다.</p><div className="form-grid"><label>출근시각<input name="clock_in_time" type="time" defaultValue={formatTimeInput(record.clock_in_at)} /></label><label>퇴근시각<input name="clock_out_time" type="time" defaultValue={formatTimeInput(record.clock_out_at)} /></label><label className="full">수정 사유<textarea name="reason" rows={3} minLength={5} placeholder="실제 시각을 변경하는 이유를 5자 이상 입력해 주세요." required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact"><Check /> 출퇴근 시각 수정</button></div></form></div>;
}

function AttendanceRequestEditModal({ request, canChangeType, onClose, onSubmit }: { request: CorrectionRequest; canChangeType: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const [requestType, setRequestType] = useState(request.request_type);
  const isClockRequest = ["clock_in_at", "clock_out_at"].includes(requestType);
  const isOvertime = requestType === "overtime";
  const isEmergency = requestType === "emergency_support";
  const isActiveEmergency = isEmergency && !request.end_time;
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="request-edit-title">
    <form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}>
      <button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button>
      <span className="kicker">{canChangeType ? "관리자 요청 수정" : "내 신청 수정"}</span>
      <h2 id="request-edit-title">{isActiveEmergency ? "긴급지원 시작시각 수정" : `${REQUEST_TYPE_LABEL[requestType] || "근태 요청"} 수정`}</h2>
      <p>{isActiveEmergency ? "실제 지원 시작일과 시작시각을 고칩니다. 종료 뒤에는 시작과 종료시각을 모두 수정할 수 있습니다." : "저장하면 다시 검토 대기 상태가 되며, 변경 전후 내용은 변경 이력에 남습니다."}</p>
      <div className="form-grid">
        {canChangeType && !isEmergency ? <label className="full">요청 항목<select name="request_type" value={requestType} onChange={(event) => setRequestType(event.target.value)} required><option value="clock_in_at">출근시각 수정</option><option value="clock_out_at">퇴근시각 수정</option><option value="annual_leave">연차 사용</option><option value="comp_time">대체휴무 사용</option><option value="sick_leave">병가</option><option value="special_leave">특별휴가</option><option value="business_trip">출장</option><option value="overtime">시간외근무</option><option value="other_leave">기타 휴가</option></select></label> : <input name="request_type" type="hidden" value={requestType} />}
        <label>{isOvertime ? "근무일" : isClockRequest ? "대상 날짜" : "시작일"}<input name="target_date" type="date" defaultValue={request.target_date} required /></label>
        {!isClockRequest && !isOvertime && !isActiveEmergency && <label>종료일<input name="end_date" type="date" defaultValue={request.end_date || request.target_date} required /></label>}
        {isClockRequest ? <label>수정 시각<input name="requested_value" type="time" defaultValue={["clock_in_at", "clock_out_at"].includes(request.request_type) ? request.requested_value.slice(0, 5) : ""} required /></label> : <>
          <label>시작시각<input name="start_time" type="time" defaultValue={(request.start_time || "09:00").slice(0, 5)} required /></label>
          {!isActiveEmergency && <label>종료시각<input name="end_time" type="time" defaultValue={(request.end_time || "18:00").slice(0, 5)} required /></label>}
        </>}
        {["special_leave", "other_leave"].includes(requestType) && <label className="full">{requestType === "special_leave" ? "특별휴가 종류" : "기타 휴가명"}<input name="request_subtype" defaultValue={request.request_subtype || ""} minLength={2} required /></label>}
        <label className="full">수정 사유와 요청 사유<textarea name="reason" rows={4} defaultValue={request.reason} minLength={5} required /></label>
      </div>
      <div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact"><Check /> {isActiveEmergency ? "시작시각 저장" : "수정하고 재검토"}</button></div>
    </form>
  </div>;
}

function RequestEditModal({ request, canChangeType, onClose, onSubmit }: { request: CorrectionRequest; canChangeType: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const [requestType, setRequestType] = useState(request.request_type);
  const isClockRequest = ["clock_in_at", "clock_out_at"].includes(requestType);
  const isOvertime = requestType === "overtime";
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="request-edit-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">관리자 요청 수정</span><h2 id="request-edit-title">{REQUEST_TYPE_LABEL[requestType] || "근태 요청"} 수정</h2><p>저장하면 다시 검토 대기 상태가 됩니다. 재승인된 연차와 휴가는 월별 출근부에 반영되며, 기존 승인 내용과 수정 이력은 보존됩니다.</p><div className="form-grid">{canChangeType ? <label className="full">요청 항목<select name="request_type" value={requestType} onChange={(event) => setRequestType(event.target.value)} required><option value="clock_in_at">출근시각 수정</option><option value="clock_out_at">퇴근시각 수정</option><option value="annual_leave">연차 사용</option><option value="comp_time">대체휴무 사용</option><option value="sick_leave">병가</option><option value="special_leave">특별휴가</option><option value="business_trip">출장</option><option value="overtime">시간외근무</option><option value="other_leave">기타 휴가</option></select></label> : <input name="request_type" type="hidden" value={requestType} />}<label>{isOvertime ? "근무일" : isClockRequest ? "대상 날짜" : "시작일"}<input name="target_date" type="date" defaultValue={request.target_date} required /></label>{!isClockRequest && !isOvertime && <label>종료일<input name="end_date" type="date" defaultValue={request.end_date || request.target_date} required /></label>}{isClockRequest ? <label>수정 시각<input name="requested_value" type="time" defaultValue={["clock_in_at", "clock_out_at"].includes(request.request_type) ? request.requested_value.slice(0, 5) : ""} required /></label> : <><label>시작시각<input name="start_time" type="time" defaultValue={(request.start_time || "09:00").slice(0, 5)} required /></label><label>종료시각<input name="end_time" type="time" defaultValue={(request.end_time || "18:00").slice(0, 5)} required /></label></>}{["special_leave", "other_leave"].includes(requestType) && <label className="full">{requestType === "special_leave" ? "특별휴가 종류" : "기타 휴가명"}<input name="request_subtype" defaultValue={request.request_subtype || ""} minLength={2} required /></label>}<label className="full">수정 사유와 요청 사유<textarea name="reason" rows={4} defaultValue={request.reason} minLength={5} required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact"><Check /> 수정하고 재검토</button></div></form></div>;
}

function CorrectionModal({ records, onClose, onSubmit }: { records: AttendanceRecord[]; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const [requestType, setRequestType] = useState("clock_in_at");
  const isTimeCorrection = requestType === "clock_in_at" || requestType === "clock_out_at";
  const isOvertime = requestType === "overtime";
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");
  const [startTime, setStartTime] = useState("09:00");
  const [endTime, setEndTime] = useState("18:00");
  const effectiveEndDate = isOvertime ? startDate : endDate || startDate;
  const calculatedMinutes = isTimeCorrection ? 0 : calculateRequestedMinutes(requestType, startDate, effectiveEndDate, startTime, endTime);
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="correction-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">근태 신청</span><h2 id="correction-title">새 근태 신청</h2><p>출퇴근 수정, 휴가, 출장, 시간외근무를 한 곳에서 신청합니다. 사용시간은 09시부터 18시까지에서 점심시간 12시부터 13시를 빼고 자동 계산합니다.</p><div className="form-grid"><label>{isTimeCorrection ? "대상 날짜" : "시작일"}<input name="target_date" type="date" value={startDate} onChange={(event) => { setStartDate(event.target.value); if (!endDate) setEndDate(event.target.value); }} max={isTimeCorrection ? currentDateKey() : undefined} required /></label><label>신청 항목<select name="request_type" value={requestType} onChange={(event) => setRequestType(event.target.value)} required><option value="clock_in_at">출근시각 수정</option><option value="clock_out_at">퇴근시각 수정</option><option value="annual_leave">연차 사용</option><option value="comp_time">대체휴무 사용</option><option value="sick_leave">병가</option><option value="special_leave">특별휴가</option><option value="business_trip">출장</option><option value="overtime">시간외근무</option><option value="other_leave">기타 휴가</option></select></label>{isTimeCorrection ? <label className="full">실제 시각<input name="requested_value" type="time" required /></label> : <><label>종료일<input name="end_date" type="date" min={startDate} value={endDate} onChange={(event) => setEndDate(event.target.value)} required /></label><label>시작시각<input name="start_time" type="time" value={startTime} onChange={(event) => setStartTime(event.target.value)} required /></label><label>종료시각<input name="end_time" type="time" value={endTime} onChange={(event) => setEndTime(event.target.value)} required /></label><div className="request-calculation"><span>자동 계산</span><strong>{requestType === "overtime" ? formatMinutes(calculatedMinutes) : `${formatMinutes(calculatedMinutes)}, ${Number((calculatedMinutes / 480).toFixed(3))}일`}</strong><small>주말은 제외되며 공휴일은 서버 저장 때 최종 반영됩니다.</small></div></>}{["special_leave", "other_leave"].includes(requestType) && <label className="full">{requestType === "special_leave" ? "특별휴가 종류" : "기타 휴가명"}<input name="request_subtype" placeholder="예: 장기재직휴가, 교육휴가" minLength={2} required /></label>}{requestType === "business_trip" && <div className="setting-info full"><AlertCircle /><p>당일 또는 여러 날의 출장 일정을 신청할 수 있습니다. 승인되면 예외 일정 목록에 자동으로 표시되며 해당 기간에는 출퇴근 기록을 생략합니다.</p></div>}{requestType === "overtime" && calculatedMinutes > 240 && <div className="form-message full"><AlertCircle />신청시간이 하루 인정 한도 4시간을 넘습니다. 실제 기록은 남지만 최대 4시간까지만 승인할 수 있습니다.</div>}<label className="full">신청 사유<textarea name="reason" rows={4} placeholder="신청 사유를 5자 이상 입력해 주세요." minLength={5} required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact"><ArrowRight /> 신청 제출</button></div><input type="hidden" value={records.length} readOnly /></form></div>;
}

function AttendanceCreateModal({ profiles, month, onClose, onSubmit }: { profiles: Profile[]; month: string; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const employees = profiles.filter((person) => person.role === "employee" && person.is_active);
  const [selectedEmployees, setSelectedEmployees] = useState<string[]>([]);
  const toggleEmployee = (id: string) => setSelectedEmployees((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="attendance-create-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">관리자 직접 등록</span><h2 id="attendance-create-title">근무기록 추가</h2><p>출퇴근을 모두 누락한 날의 실제 근무시각을 여러 직원에게 한꺼번에 등록할 수 있습니다. 직접 등록 사실과 사유는 직원별 변경 이력에 보존됩니다.</p><div className="form-grid"><fieldset className="choice-field full"><legend>직원 선택, {selectedEmployees.length}명</legend><button type="button" className="secondary-button compact" onClick={() => setSelectedEmployees(selectedEmployees.length === employees.length ? [] : employees.map((person) => person.id))}>{selectedEmployees.length === employees.length ? "전체 해제" : "전체 선택"}</button><div className="choice-grid employee-choice-grid">{employees.map((person) => <label className="choice-card" key={person.id}><input type="checkbox" name="employee_id" value={person.id} checked={selectedEmployees.includes(person.id)} onChange={() => toggleEmployee(person.id)} /><span><strong>{person.name}</strong><small>{person.employee_number}</small></span></label>)}</div></fieldset><label>근무일<input name="work_date" type="date" defaultValue={`${month}-01`} required /></label><label>출근시각<input name="clock_in_time" type="time" defaultValue="09:00" required /></label><label>퇴근시각<input name="clock_out_time" type="time" defaultValue="18:00" required /></label><label className="full">직접 등록 사유<textarea name="reason" rows={3} minLength={5} placeholder="예: 출퇴근 버튼 누락을 확인하여 관리자 직접 등록" required /></label><div className="setting-info full"><History /><p>같은 날짜에 기존 기록이 있는 직원은 제외하고 이름을 안내합니다. 나머지 선택 직원의 기록은 한꺼번에 등록됩니다.</p></div></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={selectedEmployees.length === 0}><Check /> {selectedEmployees.length}명 기록 추가</button></div></form></div>;
}

function EmployeeEmergencySupportControlModal({ activeRequest, busy, onClose, onPastSubmit, onStart, onFinish, onEdit, onCancel }: { activeRequest?: CorrectionRequest; busy: boolean; onClose: () => void; onPastSubmit: (form: HTMLFormElement) => void; onStart: (form: HTMLFormElement) => void; onFinish: (form: HTMLFormElement, request: CorrectionRequest) => void; onEdit: (request: CorrectionRequest) => void; onCancel: (request: CorrectionRequest) => void }) {
  if (!activeRequest) return <EmployeeEmergencySupportModal busy={busy} onClose={onClose} onPastSubmit={onPastSubmit} onStart={onStart} onFinish={onFinish} />;
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="employee-emergency-title">
    <form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onFinish(event.currentTarget, activeRequest); }}>
      <button type="button" className="modal-close" onClick={onClose}><X /></button>
      <div className="modal-icon"><FileClock /></div><span className="kicker">긴급지원 진행 중</span>
      <h2 id="employee-emergency-title">긴급지원 종료 또는 취소</h2>
      <p>{requestPeriodLabel(activeRequest)}입니다. 실제 시작시각이 다르면 수정하고, 지원을 가지 않게 됐다면 승인 전에 취소할 수 있습니다.</p>
      <label className="standalone-label">종료 메모, 선택<textarea name="completion_note" rows={3} placeholder="개인정보 없이 추가로 남길 업무 내용이 있을 때만 입력" /></label>
      <div className="setting-info"><ShieldCheck /><p>종료 뒤에도 관리자 승인 전까지 실제 시작과 종료시각을 수정할 수 있습니다.</p></div>
      <div className="modal-actions">
        <button type="button" className="reject-button" onClick={() => onCancel(activeRequest)} disabled={busy}><X /> 긴급지원 취소</button>
        <button type="button" className="secondary-button" onClick={() => onEdit(activeRequest)} disabled={busy}><PencilLine /> 시작시각 수정</button>
        <button className="approve-button" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 긴급지원 종료</button>
      </div>
    </form>
  </div>;
}

function EmployeeEmergencySupportModal({ activeRequest, busy, onClose, onPastSubmit, onStart, onFinish }: { activeRequest?: CorrectionRequest; busy: boolean; onClose: () => void; onPastSubmit: (form: HTMLFormElement) => void; onStart: (form: HTMLFormElement) => void; onFinish: (form: HTMLFormElement, request: CorrectionRequest) => void }) {
  const today = currentDateKey();
  const [mode, setMode] = useState<"start" | "past">("start");
  if (activeRequest) return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="employee-emergency-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onFinish(event.currentTarget, activeRequest); }}><button type="button" className="modal-close" onClick={onClose}><X /></button><div className="modal-icon"><FileClock /></div><span className="kicker">긴급지원 진행 중</span><h2 id="employee-emergency-title">현재 시각으로 종료</h2><p>{requestPeriodLabel(activeRequest)}입니다. 종료 버튼을 누르는 시각까지 실제 추가근무시간으로 계산해 승인 대기로 전환합니다.</p><label className="standalone-label">종료 메모, 선택<textarea name="completion_note" rows={3} placeholder="개인정보 없이 추가로 남길 업무 내용이 있을 때만 입력" /></label><div className="setting-info"><ShieldCheck /><p>종료 뒤에는 실제 시작과 종료시각을 확인하고, 관리자 승인 전까지 내용 수정이 가능합니다.</p></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>닫기</button><button className="approve-button" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <Check />} 긴급지원 종료</button></div></form></div>;
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="employee-emergency-title"><div className="modal correction-modal"><button type="button" className="modal-close" onClick={onClose}><X /></button><div className="modal-icon"><FileClock /></div><span className="kicker">퇴근 후 추가 근무</span><h2 id="employee-emergency-title">긴급지원 근무 기록</h2><p>지금 시작하는 지원은 시작과 종료 버튼으로 실제 시간을 기록하고, 이미 끝난 지원은 시간을 직접 입력합니다.</p><div className="request-category-tabs"><button type="button" className={mode === "start" ? "active" : ""} onClick={() => setMode("start")}>지금 시작</button><button type="button" className={mode === "past" ? "active" : ""} onClick={() => setMode("past")}>끝난 기록 입력</button></div>{mode === "start" ? <form onSubmit={(event) => { event.preventDefault(); onStart(event.currentTarget); }}><label className="standalone-label">긴급지원 내용<textarea name="reason" rows={4} minLength={5} placeholder="개인정보를 쓰지 말고 지원 업무의 종류와 발생 사유만 적어 주세요." required /></label><div className="setting-info"><Clock3 /><p>시작 버튼을 누른 시각이 자동 기록됩니다. 지원이 끝나면 반드시 긴급지원 종료 버튼을 눌러 주세요.</p></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy}>{busy ? <LoaderCircle className="spin" /> : <ArrowRight />} 긴급지원 시작</button></div></form> : <form onSubmit={(event) => { event.preventDefault(); onPastSubmit(event.currentTarget); }}><input name="request_type" type="hidden" value="emergency_support" /><div className="form-grid"><label>시작일<input name="target_date" type="date" defaultValue={today} required /></label><label>종료일<input name="end_date" type="date" defaultValue={today} required /></label><label>실제 시작시각<input name="start_time" type="time" required /></label><label>실제 종료시각<input name="end_time" type="time" required /></label><label className="full">긴급지원 내용<textarea name="reason" rows={4} minLength={5} placeholder="개인정보를 쓰지 말고 지원 업무의 종류와 발생 사유만 적어 주세요." required /></label></div><div className="setting-info"><ShieldCheck /><p>실제 종료 후 입력하며, 자정을 넘겼다면 종료일을 다음 날로 선택하세요.</p></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy}><ArrowRight /> 승인 요청</button></div></form>}</div></div>;
}

function EmergencySupportWorkModal({ profiles, busy, onClose, onSubmit }: { profiles: Profile[]; busy: boolean; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const today = currentDateKey();
  const employees = profiles.filter((person) => person.role === "employee" && person.is_active);
  const [selectedEmployees, setSelectedEmployees] = useState<string[]>([]);
  const toggleEmployee = (id: string) => setSelectedEmployees((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="admin-emergency-title"><form className="modal wide-modal workflow-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose}><X /></button><div className="modal-icon"><FileClock /></div><span className="kicker">관리자 직접 등록</span><h2 id="admin-emergency-title">긴급지원 근무 등록</h2><p>같은 긴급지원에 함께 투입된 직원을 복수 선택해 한 번에 등록합니다.</p><div className="modal-section"><div className="modal-section-heading"><strong>1. 직원 선택</strong><span>{selectedEmployees.length}명 선택</span></div><fieldset className="choice-field"><button type="button" className="secondary-button compact select-all-button" onClick={() => setSelectedEmployees(selectedEmployees.length === employees.length ? [] : employees.map((person) => person.id))}>{selectedEmployees.length === employees.length ? "전체 해제" : "전체 선택"}</button><div className="choice-grid employee-choice-grid">{employees.map((person) => <label className="choice-card" key={person.id}><input type="checkbox" name="employee_id" value={person.id} checked={selectedEmployees.includes(person.id)} onChange={() => toggleEmployee(person.id)} /><span><strong>{person.name}</strong><small>{person.employee_number}</small></span></label>)}</div></fieldset></div><div className="modal-section"><div className="modal-section-heading"><strong>2. 실제 근무시간</strong><span>자정을 넘겼다면 종료일을 다음 날로 선택</span></div><div className="form-grid compact-form-grid"><label>시작일<input name="start_date" type="date" defaultValue={today} required /></label><label>시작시각<input name="start_time" type="time" required /></label><label>종료일<input name="end_date" type="date" defaultValue={today} required /></label><label>종료시각<input name="end_time" type="time" required /></label></div></div><div className="modal-section"><div className="modal-section-heading"><strong>3. 확인 내용</strong></div><label className="standalone-label">등록 사유<textarea name="reason" rows={3} minLength={5} placeholder="개인정보 없이 긴급지원 업무와 확인 근거를 적어 주세요." required /></label><div className="setting-info"><ShieldCheck /><p>선택한 직원별로 각각 승인 기록과 변경 이력이 남습니다.</p></div></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={busy || selectedEmployees.length === 0}>{busy ? <LoaderCircle className="spin" /> : <Check />} {selectedEmployees.length}명 확인 완료로 등록</button></div></form></div>;
}

function LeaveApplyModal({ record, defaultEndTime, onClose, onSubmit }: { record: AttendanceRecord; defaultEndTime: string; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const [requestType, setRequestType] = useState("annual_leave");
  const defaultStartTime = record.clock_out_at ? formatTimeInput(record.clock_out_at) : "09:00";
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="leave-apply-title"><form className="modal correction-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">관리자 확인 반영</span><h2 id="leave-apply-title">휴가 또는 대체휴무 반영</h2><p>{record.employee_name}님의 {record.work_date} 기록에 반영할 항목을 체크하세요. 한 항목만 선택되며 번호를 입력할 필요가 없습니다.</p><div className="form-grid"><fieldset className="choice-field full"><legend>반영 항목</legend><div className="choice-grid">{[["annual_leave", "연차"], ["comp_time", "대체휴무"], ["sick_leave", "병가"], ["special_leave", "특별휴가"], ["other_leave", "기타 휴가"]].map(([value, label]) => <label className="choice-card" key={value}><input type="checkbox" name="request_type" value={value} checked={requestType === value} onChange={() => setRequestType(value)} /><span><strong>{label}</strong></span></label>)}</div></fieldset><label>시작시각<input name="start_time" type="time" defaultValue={defaultStartTime} required /></label><label>종료시각<input name="end_time" type="time" defaultValue={defaultEndTime} required /></label>{["special_leave", "other_leave"].includes(requestType) && <label className="full">{requestType === "special_leave" ? "특별휴가 종류" : "기타 휴가명"}<input name="request_subtype" placeholder="예: 장기재직휴가, 교육휴가" minLength={2} required /></label>}<label className="full">확인 내용과 반영 사유<textarea name="comment" rows={3} minLength={5} defaultValue={requestType === "comp_time" ? "관리자 확인 후 대체휴무로 반영" : "관리자 확인 후 휴가로 반영"} required /></label></div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact"><Check /> 선택 항목 반영</button></div></form></div>;
}

function ExceptionModal({ profiles, onClose, onSubmit }: { profiles: Profile[]; onClose: () => void; onSubmit: (form: HTMLFormElement) => void }) {
  const [exceptionType, setExceptionType] = useState("business_trip");
  const employees = profiles.filter((person) => person.role === "employee" && person.is_active);
  const [selectedEmployees, setSelectedEmployees] = useState<string[]>([]);
  const isLeave = ["annual_leave", "comp_time", "special_leave", "sick_leave", "other_leave"].includes(exceptionType);
  const toggleEmployee = (id: string) => setSelectedEmployees((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  return <div className="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="exception-title"><form className="modal wide-modal workflow-modal" onSubmit={(event) => { event.preventDefault(); onSubmit(event.currentTarget); }}><button type="button" className="modal-close" onClick={onClose} aria-label="닫기"><X /></button><span className="kicker">관리자 직접 등록</span><h2 id="exception-title">출퇴근 기록 예외 일정</h2><p>출장, 외부교육, 종일 휴가를 여러 직원에게 한 번에 등록합니다. 반차와 시간 단위 휴가는 직원 근태현황에서 반영해 주세요.</p><div className="modal-section"><div className="modal-section-heading"><strong>1. 직원 선택</strong><span>{selectedEmployees.length}명 선택</span></div><fieldset className="choice-field"><button type="button" className="secondary-button compact select-all-button" onClick={() => setSelectedEmployees(selectedEmployees.length === employees.length ? [] : employees.map((person) => person.id))}>{selectedEmployees.length === employees.length ? "전체 해제" : "전체 선택"}</button><div className="choice-grid employee-choice-grid">{employees.map((person) => <label className="choice-card" key={person.id}><input type="checkbox" name="employee_id" value={person.id} checked={selectedEmployees.includes(person.id)} onChange={() => toggleEmployee(person.id)} /><span><strong>{person.name}</strong><small>{person.employee_number}</small></span></label>)}</div></fieldset></div><div className="modal-section"><div className="modal-section-heading"><strong>2. 일정과 종류</strong></div><div className="form-grid compact-form-grid"><label>시작일<input name="start_date" type="date" required /></label><label>종료일<input name="end_date" type="date" required /></label><label className="full">예외 종류<select name="exception_type" value={exceptionType} onChange={(event) => setExceptionType(event.target.value)}><option value="business_trip">출장</option><option value="external_training">외부교육</option><option value="approved_other">기타 승인 예외 근무</option><option value="annual_leave">종일 연차</option><option value="comp_time">종일 대체휴무</option><option value="sick_leave">종일 병가</option><option value="special_leave">종일 특별휴가</option><option value="other_leave">종일 기타 휴가</option></select></label></div></div><div className="modal-section"><div className="modal-section-heading"><strong>3. 등록 내용</strong></div><label className="standalone-label">{exceptionType === "other_leave" ? "기타 휴가명과 사유" : exceptionType === "external_training" ? "교육명과 사유" : "사유"}<textarea name="reason" rows={3} minLength={isLeave || exceptionType === "external_training" ? 2 : undefined} placeholder={exceptionType === "other_leave" ? "예: 장기재직휴가" : exceptionType === "external_training" ? "예: 제주지역 상담원 역량강화교육" : "예: 당일 출장 또는 출장 일정"} required={exceptionType === "other_leave" || exceptionType === "external_training"} /></label>{(isLeave || exceptionType === "external_training") && <div className="setting-info"><CalendarDays /><p>{exceptionType === "external_training" ? "외부교육은 선택한 날짜마다 기본 근무시간으로 기록하고, 기존 근태기록은 덮어쓰지 않습니다." : "종일 휴가로 승인되어 월별 현황과 출근부에 반영되며, 해당 기간에는 출퇴근 버튼을 사용하지 않습니다."}</p></div>}</div><div className="modal-actions"><button type="button" className="secondary-button" onClick={onClose}>취소</button><button className="primary-button compact" disabled={selectedEmployees.length === 0}><Check /> {selectedEmployees.length}명 승인 등록</button></div></form></div>;
}
