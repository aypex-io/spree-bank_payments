/**
 * @aypex/spree-bank-payments-dashboard: the spree-bank_payments screens for
 * Spree's dashboard. Activated automatically: the package.json marker lets
 * the host's spreeDashboardPlugin() discover it.
 *
 * The back end is the gem's Admin API under /api/v3/admin/bank_payments.
 * Staff roles need read_bank_payments to see the queue and
 * write_bank_payments to act on it.
 */
import { defineDashboardPlugin, i18n } from '@spree/dashboard-core'
import en from './locales/en.json'

i18n.addResourceBundle('en', 'translation', en, true, true)

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
