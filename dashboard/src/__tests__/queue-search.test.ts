import { describe, expect, it } from 'vitest'
import { queueSearch, unmatchedOnly } from '../queue-search'

// The queue opens on unmatched transfers, but clearing the filter (Clear all,
// or Select all in the status chip) must show every transfer. The table
// writes page=1 whenever it changes the filters, so a visit with no search
// state at all is the only one that gets the default.
describe('queueSearch', () => {
  it('opens a fresh visit on unmatched transfers', () => {
    expect(queueSearch({}).filters).toEqual([unmatchedOnly])
  })

  it('shows every transfer once the filters are cleared', () => {
    expect(queueSearch({ page: '1' }).filters).toEqual([])
  })

  it('keeps the filters the table wrote', () => {
    const applied = { id: 'state', field: 'state', operator: 'in', value: 'applied' }
    expect(queueSearch({ page: '1', filters: JSON.stringify([applied]) }).filters).toEqual([
      applied,
    ])
  })

  it('keeps the other search state', () => {
    expect(queueSearch({ page: '2', search: 'ACME' })).toEqual(
      expect.objectContaining({ page: 2, search: 'ACME', filters: [] }),
    )
  })
})
