import { createFileRoute, type SearchSchemaInput } from '@tanstack/react-router'
import { TransfersListPage } from '../pages/transfers-list'
import { queueSearch } from '../queue-search'

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/')({
  // SearchSchemaInput tells the router what a link may pass: any search, or
  // none. Without it the router takes the parsed output as the input, and every
  // navigation to the queue would have to spell out the whole search state.
  validateSearch: (search: Record<string, unknown> & SearchSchemaInput) => queueSearch(search),
  component: BankTransfersRoute,
})

function BankTransfersRoute() {
  return <TransfersListPage searchParams={Route.useSearch()} />
}
