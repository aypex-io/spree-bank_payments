import './i18n'
import { defineTable, i18n } from '@spree/dashboard-core'
import { Badge, RelativeTime } from '@spree/dashboard-ui'
import { money, TransferReferenceLink, TransferStateBadge } from './components/shared'
import type { IncomingTransfer } from './types'

/**
 * The bank transfers queue's table, for ResourceTable. Its own module, so
 * the package entry stays a .ts file: Vite only pre-bundles a dependency
 * whose entry is .js or .ts, and an un-bundled plugin's imports reach
 * CommonJS packages the dev server cannot serve.
 */
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
      render: (transfer) => <TransferReferenceLink transfer={transfer} />,
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
