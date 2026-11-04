/**
 * Typed wrappers over adminClient.request for the gem's Admin API. Paths are
 * relative to /api/v3/admin. Screens and slots call these, never
 * adminClient directly, so an endpoint changes in one place.
 */
import type { PaginatedResponse } from '@spree/admin-sdk'
import { adminClient } from '@spree/dashboard-core'
import { listQuery } from './list-query'
import type {
  BankAccount,
  BankAccountParams,
  BankTransferMethod,
  GatewayHealth,
  IncomingTransfer,
  OrderBankTransfer,
  RecordedTransfer,
  RecordTransferParams,
  Suggestion,
  SyncPlan,
} from './types'

export type ListParams = Record<string, string | number | boolean | (string | number)[] | undefined>

const base = '/bank_payments'

export const bankPaymentsClient = {
  /** The store's bank transfer payment methods, under the bank transfers permission. */
  paymentMethods: () =>
    adminClient.request<{ data: BankTransferMethod[] }>('GET', `${base}/payment_methods`),
  transfers: {
    list: (params?: ListParams) =>
      adminClient.request<PaginatedResponse<IncomingTransfer>>('GET', `${base}/transfers`, {
        params: listQuery(params),
      }),
    get: (id: string) => adminClient.request<IncomingTransfer>('GET', `${base}/transfers/${id}`),
    suggestions: (id: string) =>
      adminClient.request<{ data: Suggestion[] }>('GET', `${base}/transfers/${id}/suggestions`),
    record: (body: RecordTransferParams) =>
      adminClient.request<RecordedTransfer>('POST', `${base}/transfers`, { body }),
    apply: (id: string, body: { payment_session_id: string; confirm_mismatch?: boolean }) =>
      adminClient.request<IncomingTransfer>('POST', `${base}/transfers/${id}/apply`, { body }),
    ignore: (id: string, reason: string) =>
      adminClient.request<IncomingTransfer>('POST', `${base}/transfers/${id}/ignore`, {
        body: { reason },
      }),
  },
  accounts: {
    list: (paymentMethodId: string) =>
      adminClient.request<{ data: BankAccount[] }>(
        'GET',
        `${base}/payment_methods/${paymentMethodId}/accounts`,
      ),
    create: (paymentMethodId: string, body: BankAccountParams) =>
      adminClient.request<BankAccount>(
        'POST',
        `${base}/payment_methods/${paymentMethodId}/accounts`,
        {
          body,
        },
      ),
    update: (paymentMethodId: string, id: string, body: BankAccountParams) =>
      adminClient.request<BankAccount>(
        'PATCH',
        `${base}/payment_methods/${paymentMethodId}/accounts/${id}`,
        { body },
      ),
    destroy: (paymentMethodId: string, id: string) =>
      adminClient.request<void>(
        'DELETE',
        `${base}/payment_methods/${paymentMethodId}/accounts/${id}`,
      ),
    syncPlan: (paymentMethodId: string) =>
      adminClient.request<SyncPlan>(
        'GET',
        `${base}/payment_methods/${paymentMethodId}/accounts/sync_plan`,
      ),
    sync: (paymentMethodId: string) =>
      adminClient.request<{ data: BankAccount[] }>(
        'POST',
        `${base}/payment_methods/${paymentMethodId}/accounts/sync`,
      ),
  },
  orderPanel: (orderId: string) =>
    adminClient.request<OrderBankTransfer>('GET', `${base}/orders/${orderId}`),
  health: (paymentMethodId: string) =>
    adminClient.request<GatewayHealth>('GET', `${base}/payment_methods/${paymentMethodId}/health`),
}
