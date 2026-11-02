import { createFileRoute } from '@tanstack/react-router'
import { TransferDetailPage } from '../pages/transfer-detail'

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/$transferId')({
  component: BankTransferRoute,
})

function BankTransferRoute() {
  const { transferId } = Route.useParams()
  return <TransferDetailPage transferId={transferId} />
}
