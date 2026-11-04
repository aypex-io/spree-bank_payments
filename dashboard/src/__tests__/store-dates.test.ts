import { describe, expect, it } from 'vitest'
import { todayIn } from '../store-dates'

// The record form's date is the day the money arrived on the store's
// calendar. The browser's UTC date is a day ahead every evening west of UTC.
describe('todayIn', () => {
  const lateEveningInNewYork = new Date('2026-11-05T03:00:00Z')

  it("is the store's date, not the UTC one", () => {
    expect(todayIn('America/New_York', lateEveningInNewYork)).toBe('2026-11-04')
  })

  it('is the date where the store is', () => {
    expect(todayIn('Europe/London', lateEveningInNewYork)).toBe('2026-11-05')
  })

  it('pads the month and the day', () => {
    expect(todayIn('UTC', new Date('2026-03-07T12:00:00Z'))).toBe('2026-03-07')
  })

  it('falls back to UTC for a zone it cannot read', () => {
    expect(todayIn('Nowhere/Special', lateEveningInNewYork)).toBe('2026-11-05')
  })
})
