/**
 * Today's date where the store is, as a date input's value (`YYYY-MM-DD`).
 * The record form defaults to it: the browser's UTC date is a day ahead every
 * evening west of UTC, and the server reads the date on the store's calendar.
 * A zone `Intl` cannot read falls back to UTC.
 */
export function todayIn(timeZone: string, now: Date = new Date()): string {
  let format: Intl.DateTimeFormat
  try {
    format = new Intl.DateTimeFormat('en-US', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    })
  } catch {
    return now.toISOString().slice(0, 10)
  }
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    format.formatToParts(now).find((p) => p.type === type)?.value
  return `${part('year')}-${part('month')}-${part('day')}`
}
