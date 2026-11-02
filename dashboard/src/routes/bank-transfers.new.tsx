import { createFileRoute } from '@tanstack/react-router'
import { RecordTransferPage } from '../pages/record-transfer'

export const Route = createFileRoute('/_authenticated/$storeId/bank-transfers/new')({
  component: RecordTransferPage,
})
