import { formatMoney } from '@spree/admin-sdk'
import { formatStoreDate, i18n, usePermissions, useStore } from '@spree/dashboard-core'
import { Badge } from '@spree/dashboard-ui'
import { Link, useParams } from '@tanstack/react-router'
import type { IncomingTransfer, TransferState } from '../types'

/** Money as the admin's language writes it, from the API's decimal string. */
export function money(amount: string | null | undefined, currency: string): string {
  return formatMoney(amount, currency, i18n.language)
}

/**
 * The day a transfer arrived, on the store's calendar. A recorded transfer
 * carries only the day, so a relative time ("about 23 hours ago") misstates
 * when it came, and a bank statement lists it by date anyway.
 */
export function StoreDate({ iso }: { iso: string }) {
  const { timezone } = useStore()
  return <>{formatStoreDate(iso, timezone)}</>
}

const stateVariant: Record<TransferState, 'warning' | 'success' | 'secondary'> = {
  unmatched: 'warning',
  applied: 'success',
  ignored: 'secondary',
}

export function TransferStateBadge({ state }: { state: TransferState }) {
  return (
    <Badge variant={stateVariant[state]}>{i18n.t(`admin.bank_payments.states.${state}`)}</Badge>
  )
}

/**
 * Whether the signed-in staff member may act on bank transfers (apply,
 * ignore, record, manage accounts): the write_bank_payments permission.
 * The Admin API refuses them anyway; this hides controls they cannot use.
 */
export function useCanManageBankTransfers(): boolean {
  return usePermissions().permissions.can('update', 'incoming_transfer')
}

/**
 * The current store's id, from the `$storeId` every dashboard route sits
 * under. Links must pass it: the router does not fill it in.
 */
export function useStoreId(): string {
  const { storeId } = useParams({ strict: false }) as { storeId?: string }
  return storeId ?? ''
}

/** A transfer's reference, linking to its page. */
export function TransferReferenceLink({ transfer }: { transfer: IncomingTransfer }) {
  const storeId = useStoreId()

  return (
    <Link
      to="/$storeId/bank-transfers/$transferId"
      params={{ storeId, transferId: transfer.id }}
      className="font-medium text-foreground no-underline"
    >
      {transfer.reference || '—'}
    </Link>
  )
}
