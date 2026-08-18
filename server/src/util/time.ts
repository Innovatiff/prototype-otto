/**
 * Wall-clock helpers. Every "what day/time is this for the user" question is
 * answered by formatting the instant INTO the user's timezone — never by
 * UTC offset arithmetic. Invalid timezones fall back to UTC.
 */

/** The wall date (YYYY-MM-DD) of an instant in a timezone. */
export function wallDate(at: Date, timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(at);
  } catch {
    return at.toISOString().slice(0, 10);
  }
}

/** The wall clock time (h:mm AM/PM) of an instant in a timezone. */
export function wallTime(iso: string, timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    }).format(new Date(iso));
  } catch {
    return iso.slice(11, 16);
  }
}
