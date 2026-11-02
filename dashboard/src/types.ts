/**
 * Records the spree-bank_payments Admin API returns, under
 * /api/v3/admin/bank_payments. Hand-written to match the gem's serializers
 * (app/serializers/spree/api/v3/admin/bank_payments/); money is a decimal
 * string with the currency's decimals ("97.00").
 */

export interface DetailSet {
  label?: string
  schemes?: string[]
  beneficiary_name?: string
  beneficiary_address?: string
  fields: { label: string; value: string }[]
}

export type TransferState = 'unmatched' | 'applied' | 'ignored'

export interface IncomingTransfer {
  id: string
  state: TransferState
  amount: string
  currency: string
  provider: string
  /** As the payer typed it. */
  reference: string | null
  payer_name: string | null
  occurred_at: string
  applied_at: string | null
  ignored_reason: string | null
  payment_method_id: string | null
  payment_session_id: string | null
  bank_account: {
    id: string
    currency: string
    provider_account_id: string | null
    pooled: boolean
  } | null
  order: { id: string; number: string } | null
}

export interface RecordedTransfer extends IncomingTransfer {
  /** True when the same transfer had been recorded before: nothing was applied twice. */
  already_recorded: boolean
}

/** An open bank transfer session an unmatched transfer could belong to. `id` is the session's. */
export interface Suggestion {
  id: string
  reference: string
  amount: string
  currency: string
  expires_at: string | null
  exact_match: boolean
  order: { id: string; number: string; email: string | null; customer_name: string | null }
}

export interface RecordTransferParams {
  payment_method_id: string
  amount: string
  currency: string
  reference: string
  payer_name?: string
  /** The date the money arrived, YYYY-MM-DD. */
  occurred_at: string
}

export interface BankAccount {
  id: string
  currency: string
  offered: boolean
  active: boolean
  pooled: boolean
  /** Synced from the provider: refreshed by syncing, deactivated rather than deleted. */
  synced: boolean
  provider_account_id: string | null
  detail_sets: DetailSet[]
  created_at: string
}

export interface BankAccountParams {
  currency?: string
  offered?: boolean
  active?: boolean
  details?: DetailSet[]
}

export interface ReportedAccount {
  provider_account_id: string
  currency: string
  pooled: boolean
  detail_sets: DetailSet[]
}

export interface SyncPlan {
  create: ReportedAccount[]
  update: ReportedAccount[]
  deactivate: BankAccount[]
  skipped: ReportedAccount[]
}

export interface BankTransferSession {
  id: string
  reference: string
  status: 'pending' | 'processing' | 'completed' | 'failed' | 'canceled' | 'expired'
  amount: string
  currency: string
  expires_at: string | null
  bank_details: DetailSet[]
}

export interface OrderBankTransfer {
  sessions: BankTransferSession[]
  transfers: IncomingTransfer[]
}

export interface GatewayHealth {
  health: 'ok' | 'transient' | 'consent_revoked'
  reconciler: string
  last_successful_run_at: string | null
  last_error: string | null
  consecutive_failures: number
  webhook_url: string | null
  /** Currencies with an offered account. Empty: bank transfer is offered nowhere. */
  offered_currencies: string[]
}

/** The Admin API's error body, `{ error: { code, message, details } }`. */
export interface AmountMismatchDetails {
  transfer_amount: string
  transfer_currency: string
  session_amount: string
  currency: string
}
