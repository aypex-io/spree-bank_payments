import { createFileRoute } from '@tanstack/react-router'
import { AccountsPage } from '../pages/accounts'

export const Route = createFileRoute(
  '/_authenticated/$storeId/bank-transfers/accounts/$paymentMethodId',
)({
  component: AccountsRoute,
})

function AccountsRoute() {
  const { paymentMethodId } = Route.useParams()
  return <AccountsPage paymentMethodId={paymentMethodId} />
}
