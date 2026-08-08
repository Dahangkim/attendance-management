import { NextResponse } from "next/server";

const GOOGLE_KOREAN_HOLIDAYS_ICS = "https://calendar.google.com/calendar/ical/ko.south_korea%23holiday%40group.v.calendar.google.com/public/basic.ics";

const decodeIcsText = (value: string) => value.replaceAll("\\n", " ").replaceAll("\\,", ",").replaceAll("\\;", ";").replaceAll("\\\\", "\\").trim();

export async function GET(request: Request) {
  const year = Number(new URL(request.url).searchParams.get("year"));
  if (!Number.isInteger(year) || year < 2026 || year > 2100) return NextResponse.json({ error: "INVALID_YEAR" }, { status: 400 });
  try {
    const response = await fetch(GOOGLE_KOREAN_HOLIDAYS_ICS, { cache: "no-store", headers: { accept: "text/calendar" } });
    if (!response.ok) return NextResponse.json({ error: "GOOGLE_CALENDAR_UNAVAILABLE" }, { status: 502 });
    const ics = (await response.text()).replace(/\r?\n[ \t]/g, "");
    const holidays = ics.split("BEGIN:VEVENT").slice(1).map((event) => {
      const date = event.match(/DTSTART(?:;[^:]*)?:(\d{4})(\d{2})(\d{2})/)?.slice(1, 4);
      const summary = event.match(/SUMMARY(?:;[^:]*)?:(.*)/)?.[1];
      const description = event.match(/DESCRIPTION(?:;[^:]*)?:(.*)/)?.[1];
      if (!date || !summary || decodeIcsText(description || "") !== "공휴일") return null;
      return { holiday_date: `${date[0]}-${date[1]}-${date[2]}`, holiday_name: decodeIcsText(summary), is_paid_holiday: true };
    }).filter((holiday): holiday is { holiday_date: string; holiday_name: string; is_paid_holiday: boolean } => Boolean(holiday && holiday.holiday_date.startsWith(`${year}-`)));
    const unique = [...new Map(holidays.map((holiday) => [holiday.holiday_date, holiday])).values()].sort((a, b) => a.holiday_date.localeCompare(b.holiday_date));
    return NextResponse.json({ year, source: "Google Calendar 대한민국 공휴일", holidays: unique });
  } catch {
    return NextResponse.json({ error: "HOLIDAY_IMPORT_FAILED" }, { status: 502 });
  }
}
