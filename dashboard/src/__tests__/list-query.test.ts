import { describe, expect, it } from 'vitest'
import { listQuery } from '../list-query'

// The dashboard's ResourceTable hands a list call flat Ransack predicates
// (state_in, reference_raw_or_payer_name_cont, occurred_at_gteq). Spree's
// Admin API reads filters only from q[...], so they must be wrapped, as the
// SDK's own resource clients do.
describe('listQuery', () => {
  it('wraps a filter in q', () => {
    expect(listQuery({ state_in: 'unmatched' })).toEqual({ 'q[state_in]': 'unmatched' })
  })

  it('wraps a list filter as an array', () => {
    expect(listQuery({ state_in: ['unmatched', 'ignored'] })).toEqual({
      'q[state_in][]': ['unmatched', 'ignored'],
    })
  })

  it('wraps the search', () => {
    expect(listQuery({ reference_raw_or_payer_name_cont: 'ACME' })).toEqual({
      'q[reference_raw_or_payer_name_cont]': 'ACME',
    })
  })

  it('passes paging and sorting through', () => {
    expect(listQuery({ page: 2, limit: 25, sort: '-occurred_at' })).toEqual({
      page: 2,
      limit: 25,
      sort: '-occurred_at',
    })
  })

  it('keeps a filter already in q form', () => {
    expect(listQuery({ 'q[state_eq]': 'applied' })).toEqual({ 'q[state_eq]': 'applied' })
  })

  it('drops what is not set', () => {
    expect(listQuery({ state_in: undefined, page: 1 })).toEqual({ page: 1 })
  })

  it('sends nothing for no params', () => {
    expect(listQuery(undefined)).toBeUndefined()
  })
})
