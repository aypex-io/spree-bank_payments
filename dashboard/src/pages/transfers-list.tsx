import { type ResourceSearch, ResourceTable } from '@spree/dashboard-core'
import { buttonVariants } from '@spree/dashboard-ui/ui/button'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'
import { useCanManageBankTransfers } from '../components/shared'

export const transfersQueryKey = 'bank_transfers'

/** The hand-match queue: unmatched transfers, newest first, paginated by the API. */
export function TransfersListPage({ searchParams }: { searchParams: ResourceSearch }) {
  const { t } = useTranslation()
  const canManage = useCanManageBankTransfers()

  return (
    <ResourceTable
      tableKey="bank_transfers"
      queryKey={transfersQueryKey}
      queryFn={(params) => bankPaymentsClient.transfers.list(params)}
      searchParams={searchParams}
      actions={
        canManage ? (
          <Link to="/$storeId/bank-transfers/new" className={buttonVariants({ size: 'sm' })}>
            {t('admin.bank_payments.queue.record')}
          </Link>
        ) : null
      }
    />
  )
}
