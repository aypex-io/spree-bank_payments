import { resourceSearchSchema } from '@spree/dashboard-core'
import { createFileRoute } from '@tanstack/react-router'
import { TransfersListPage } from '../pages/transfers-list'

/**
 * The queue opens on unmatched transfers, the ones waiting for staff. The
 * rule is the status quick filter's own, so the chip shows it and "Any
 * status" clears it to list every transfer.
 */
const unmatchedOnly = {
  id: 'bank-transfers-unmatched',
  field: 'state',
  operator: 'in',
  value: 'unmatched',
}

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/')({
  validateSearch: (search: Record<string, unknown>) => {
    const parsed = resourceSearchSchema.parse(search)
    return search.filters === undefined ? { ...parsed, filters: [unmatchedOnly] } : parsed
  },
  component: BankTransfersRoute,
})

function BankTransfersRoute() {
  return <TransfersListPage searchParams={Route.useSearch()} />
}
