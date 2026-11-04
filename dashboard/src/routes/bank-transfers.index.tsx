import { createFileRoute } from '@tanstack/react-router'
import { TransfersListPage } from '../pages/transfers-list'
import { queueSearch } from '../queue-search'

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/')({
  validateSearch: queueSearch,
  component: BankTransfersRoute,
})

function BankTransfersRoute() {
  return <TransfersListPage searchParams={Route.useSearch()} />
}
