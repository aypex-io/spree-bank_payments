/**
 * @aypex/spree-bank-payments-dashboard: the spree-bank_payments screens for
 * Spree's dashboard. Activated automatically: the package.json marker lets
 * the host's spreeDashboardPlugin() discover it.
 *
 * The back end is the gem's Admin API under /api/v3/admin/bank_payments.
 * Staff roles need read_bank_payments to see the queue and
 * write_bank_payments to act on it.
 */
import { defineDashboardPlugin, defineTable, i18n } from '@spree/dashboard-core'
import { RelativeTime } from '@spree/dashboard-ui'
import { Badge } from '@spree/dashboard-ui/ui/badge'
import { Link } from '@tanstack/react-router'
import { money, TransferStateBadge } from './components/shared'
import en from './locales/en.json'
import type { IncomingTransfer } from './types'

i18n.addResourceBundle('en', 'translation', en, true, true)

const label = (key: string) => i18n.t(`admin.bank_payments.${key}`)

defineTable<IncomingTransfer>('bank_transfers', {
  title: label('queue.title'),
  searchParam: 'reference_raw_or_payer_name_cont',
  searchPlaceholder: label('queue.search_placeholder'),
  defaultSort: { field: 'occurred_at', direction: 'desc' },
  emptyMessage: label('queue.empty'),
  columns: [
    {
      key: 'occurred_at',
      label: label('fields.occurred_at'),
      sortable: true,
      default: true,
      filterType: 'date',
      render: (transfer) => <RelativeTime iso={transfer.occurred_at} />,
    },
    {
      key: 'amount',
      label: label('fields.amount'),
      sortable: true,
      default: true,
      className: 'text-right tabular-nums',
      render: (transfer) => money(transfer.amount, transfer.currency),
    },
    {
      key: 'reference',
      label: label('fields.reference'),
      ransackAttribute: 'reference_raw',
      default: true,
      render: (transfer) => (
        <Link
          to="/$storeId/bank-transfers/$transferId"
          params={{ transferId: transfer.id } as never}
          className="font-medium text-foreground no-underline"
        >
          {transfer.reference || '—'}
        </Link>
      ),
    },
    {
      key: 'payer_name',
      label: label('fields.payer_name'),
      default: true,
    },
    {
      key: 'account',
      label: label('fields.account'),
      default: true,
      render: (transfer) =>
        transfer.bank_account ? (
          <span className="flex items-center gap-2">
            {transfer.bank_account.currency}
            {transfer.bank_account.pooled ? (
              <Badge variant="outline">{label('pooled')}</Badge>
            ) : null}
          </span>
        ) : (
          '—'
        ),
    },
    {
      key: 'state',
      label: label('fields.state'),
      default: true,
      filterable: true,
      quickFilter: true,
      filterType: 'enum',
      filterOptions: (['unmatched', 'applied', 'ignored'] as const).map((state) => ({
        value: state,
        label: label(`states.${state}`),
      })),
      render: (transfer) => <TransferStateBadge state={transfer.state} />,
    },
  ],
})

defineDashboardPlugin({
  nav: {
    addChildren: {
      orders: [
        {
          key: 'orders.bank_transfers',
          label: i18n.t('admin.bank_payments.nav'),
          path: '/bank-transfers',
          position: 500,
          subject: 'incoming_transfer',
        },
      ],
    },
  },
})

export { bankPaymentsClient } from './client'
export type * from './types'
