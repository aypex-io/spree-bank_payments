import { resourceSearchSchema } from '@spree/dashboard-core'

/**
 * The queue's default: unmatched transfers, the ones waiting for staff. It
 * is the status quick filter's own rule, so the chip shows it.
 */
export const unmatchedOnly = {
  id: 'bank-transfers-unmatched',
  field: 'state',
  operator: 'in',
  value: 'unmatched',
}

/**
 * The queue's search state. Only a visit with no search state at all, the
 * one the sidebar link makes, opens on unmatched transfers. The table writes
 * `page=1` whenever it changes the filters, so once staff clear them (Clear
 * all, or Select all in the status chip) every transfer is listed instead of
 * the default coming straight back.
 */
export function queueSearch(search: Record<string, unknown>) {
  const parsed = resourceSearchSchema.parse(search)
  const freshVisit = search.filters === undefined && search.page === undefined
  return freshVisit ? { ...parsed, filters: [unmatchedOnly] } : parsed
}
