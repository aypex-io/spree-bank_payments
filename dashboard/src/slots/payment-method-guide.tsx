import { useResourceKey } from '@spree/dashboard-core'
import { CopyToClipboardButton, RelativeTime } from '@spree/dashboard-ui'
import { Alert, AlertDescription, AlertTitle } from '@spree/dashboard-ui/ui/alert'
import { Badge } from '@spree/dashboard-ui/ui/badge'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'

const healthVariant = {
  ok: 'success',
  transient: 'warning',
  consent_revoked: 'destructive',
} as const

/**
 * The bank transfer payment method's setup guide
 * (`payment_method.guide.bank_transfer`): reconciler health, the webhook URL
 * to paste into the provider, and a plain warning while no account is
 * offered. Nothing in create mode: there is no gateway to ask yet.
 */
export function PaymentMethodGuide({ paymentMethod }: { paymentMethod: { id: string } | null }) {
  const { t } = useTranslation()
  const { data: health } = useQuery({
    queryKey: useResourceKey('bank_payment_health', paymentMethod?.id),
    queryFn: () => bankPaymentsClient.health(paymentMethod!.id),
    enabled: Boolean(paymentMethod),
  })

  if (!paymentMethod || !health) return null

  return (
    <div className="flex flex-col gap-3">
      {health.offered_currencies.length === 0 ? (
        <Alert variant="destructive">
          <AlertDescription>{t('admin.bank_payments.guide.no_offered_account')}</AlertDescription>
        </Alert>
      ) : null}
      <Alert>
        <AlertTitle className="flex items-center gap-2">
          {t('admin.bank_payments.guide.title')}
          <Badge variant={healthVariant[health.health]}>
            {t(`admin.bank_payments.guide.health_${health.health}`)}
          </Badge>
        </AlertTitle>
        <AlertDescription className="flex flex-col gap-1">
          <span>
            {t('admin.bank_payments.guide.health')}: {health.reconciler}
          </span>
          <span>
            {t('admin.bank_payments.guide.last_poll')}:{' '}
            <RelativeTime
              iso={health.last_successful_run_at}
              fallback={t('admin.bank_payments.guide.never')}
            />
          </span>
          {health.last_error ? (
            <span>
              {t('admin.bank_payments.guide.last_error')}: {health.last_error}
            </span>
          ) : null}
          {health.offered_currencies.length > 0 ? (
            <span>
              {t('admin.bank_payments.guide.offered_in', {
                currencies: health.offered_currencies.join(', '),
              })}
            </span>
          ) : null}
          {health.webhook_url ? (
            <span className="flex items-center gap-1">
              {t('admin.bank_payments.guide.webhook_url')}:{' '}
              <code className="break-all">{health.webhook_url}</code>
              <CopyToClipboardButton
                value={health.webhook_url}
                aria-label={t('admin.bank_payments.copy')}
              />
            </span>
          ) : null}
        </AlertDescription>
      </Alert>
    </div>
  )
}
