import { buttonVariants } from '@spree/dashboard-ui/ui/button'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

/** A Bank accounts link in the payment method sheet's footer (`payment_method.actions.bank_transfer`). */
export function PaymentMethodActions({ paymentMethod }: { paymentMethod: { id: string } | null }) {
  const { t } = useTranslation()

  if (!paymentMethod) return null

  return (
    <Link
      to="/$storeId/bank-transfers/accounts/$paymentMethodId"
      params={{ paymentMethodId: paymentMethod.id } as never}
      className={buttonVariants({ variant: 'outline', size: 'sm' })}
    >
      {t('admin.bank_payments.guide.accounts_link')}
    </Link>
  )
}
