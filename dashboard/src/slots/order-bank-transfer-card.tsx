import { useResourceKey } from '@spree/dashboard-core'
import { CopyToClipboardButton, RelativeTime } from '@spree/dashboard-ui'
import { Card, CardContent, CardHeader, CardTitle } from '@spree/dashboard-ui/ui/card'
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'
import { money } from '../components/shared'

/**
 * The order page's bank transfer card (`order.form_sidebar`): the reference,
 * amount and deadline the buyer was quoted, and any transfer applied. Renders
 * nothing for an order paid another way.
 */
export function OrderBankTransferCard({ order }: { order: { id: string } }) {
  const { t } = useTranslation()
  const { data } = useQuery({
    queryKey: useResourceKey('bank_transfer_orders', order.id),
    queryFn: () => bankPaymentsClient.orderPanel(order.id),
  })
  const session = data?.sessions.at(-1)

  if (!session) return null

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('admin.bank_payments.order_card.title')}</CardTitle>
      </CardHeader>
      <CardContent>
        <dl className="flex flex-col gap-2 text-sm">
          <div className="flex items-center justify-between gap-2">
            <dt className="text-muted-foreground">
              {t('admin.bank_payments.order_card.reference')}
            </dt>
            <dd className="flex items-center gap-1 font-mono">
              {session.reference}
              <CopyToClipboardButton
                value={session.reference}
                aria-label={t('admin.bank_payments.copy')}
              />
            </dd>
          </div>
          <div className="flex justify-between gap-2">
            <dt className="text-muted-foreground">{t('admin.bank_payments.order_card.amount')}</dt>
            <dd>{money(session.amount, session.currency)}</dd>
          </div>
          <div className="flex justify-between gap-2">
            <dt className="text-muted-foreground">{t('admin.bank_payments.order_card.status')}</dt>
            <dd>{t(`admin.bank_payments.session_status.${session.status}`)}</dd>
          </div>
          {session.status === 'processing' || session.status === 'pending' ? (
            <div className="flex justify-between gap-2">
              <dt className="text-muted-foreground">
                {t('admin.bank_payments.order_card.deadline')}
              </dt>
              <dd>
                <RelativeTime iso={session.expires_at} />
              </dd>
            </div>
          ) : null}
        </dl>
        {(data?.transfers ?? []).map((transfer) => (
          <p key={transfer.id} className="mt-3 text-sm">
            <Link
              to="/$storeId/bank-transfers/$transferId"
              params={{ transferId: transfer.id } as never}
            >
              {t('admin.bank_payments.order_card.transfer', {
                date: new Date(transfer.occurred_at).toLocaleDateString(),
              })}
            </Link>
          </p>
        ))}
      </CardContent>
    </Card>
  )
}
