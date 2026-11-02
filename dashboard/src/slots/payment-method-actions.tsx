import { buttonVariants } from '@spree/dashboard-ui'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { useStoreId } from '../components/shared'

/** A Bank accounts link in the payment method sheet's footer (`payment_method.actions.bank_transfer`). */
export function PaymentMethodActions({ paymentMethod }: { paymentMethod: { id: string } | null }) {
  const { t } = useTranslation()
  const storeId = useStoreId()

  if (!paymentMethod) return null

  return (
    <Link
      to="/$storeId/bank-transfers/accounts/$paymentMethodId"
      params={{ storeId, paymentMethodId: paymentMethod.id }}
      className={buttonVariants({ variant: 'outline', size: 'sm' })}
    >
      {t('admin.bank_payments.guide.accounts_link')}
    </Link>
  )
}
