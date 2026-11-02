import { resourceSearchSchema } from '@spree/dashboard-core'
import { createFileRoute } from '@tanstack/react-router'
import { TransfersListPage } from '../pages/transfers-list'

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/')({
  validateSearch: resourceSearchSchema,
  component: BankTransfersRoute,
})

function BankTransfersRoute() {
  return <TransfersListPage searchParams={Route.useSearch()} />
}
