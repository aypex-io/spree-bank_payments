import { formatMoney } from '@spree/admin-sdk'
import { i18n, usePermissions } from '@spree/dashboard-core'
import { Badge } from '@spree/dashboard-ui/ui/badge'
import type { TransferState } from '../types'

/** Money as the admin's language writes it, from the API's decimal string. */
export function money(amount: string | null | undefined, currency: string): string {
  return formatMoney(amount, currency, i18n.language)
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
