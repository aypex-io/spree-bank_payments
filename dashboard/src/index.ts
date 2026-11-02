/**
 * @aypex/spree-bank-payments-dashboard: the spree-bank_payments screens for
 * Spree's dashboard. Activated automatically: the package.json marker lets
 * the host's spreeDashboardPlugin() discover it.
 *
 * The back end is the gem's Admin API under /api/v3/admin/bank_payments.
 * Staff roles need read_bank_payments to see the queue and
 * write_bank_payments to act on it.
 *
 * A .ts file, not .tsx: Vite pre-bundles a dependency only when its entry is
 * .js or .ts, and the dev server cannot serve this plugin's imports un-bundled.
 */
import './i18n'
import './table'
import { defineDashboardPlugin, i18n } from '@spree/dashboard-core'
import { OrderBankTransferCard } from './slots/order-bank-transfer-card'
import { PaymentMethodActions } from './slots/payment-method-actions'
import { PaymentMethodGuide } from './slots/payment-method-guide'

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
  // The slots' contexts are typed by the host pages; `defineDashboardPlugin`
  // erases them, hence the casts. Slot names are literal strings: the
  // helpers that build them live in the app shell, which a plugin must not
  // import.
  slots: {
    'order.form_sidebar': [
      { id: 'bank-transfer', component: OrderBankTransferCard as never, position: 250 },
    ],
    'payment_method.guide.bank_transfer': [
      { id: 'bank-transfer-guide', component: PaymentMethodGuide as never, position: 100 },
    ],
    'payment_method.actions.bank_transfer': [
      { id: 'bank-transfer-accounts', component: PaymentMethodActions as never, position: 100 },
    ],
  },
})

export { bankPaymentsClient } from './client'
export type * from './types'
