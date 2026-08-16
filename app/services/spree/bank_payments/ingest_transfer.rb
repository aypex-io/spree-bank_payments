module Spree
  module BankPayments
    class IngestTransfer
      def initialize(payment_method:, transfer_data:)
        @payment_method = payment_method
        @data = transfer_data
      end

      def call
        transfer = find_or_create_transfer

        # Webhook and poll both delivering the same transfer is the expected
        # case, not an error. The unique index makes replay a no-op.
        return transfer if transfer.applied?

        session = matching_session(transfer)
        return transfer unless session

        # ApplyTransfer returns the transfer it was handed.
        ApplyTransfer.call(transfer: transfer, payment_session: session)
      end

      private

      attr_reader :payment_method, :data

      def find_or_create_transfer
        IncomingTransfer.create_with(
          amount: data.amount,
          currency: data.currency,
          reference_raw: data.reference,
          payer_name: data.payer_name,
          occurred_at: data.occurred_at,
          raw_payload: data.raw || {},
          state: 'unmatched',
          payment_method_id: payment_method.id,
          bank_account_id: arriving_bank_account&.id
        ).find_or_create_by!(
          provider: data.provider,
          provider_transaction_id: data.provider_transaction_id
        )
      end

      # Watched, not offered: a transfer into an account the merchant has since
      # stopped offering must still reconcile, or switching accounts would
      # strand orders already in flight.
      def arriving_bank_account
        return nil if data.provider_account_id.blank?

        @arriving_bank_account ||= payment_method.bank_accounts.active.
          find_by(provider_account_id: data.provider_account_id)
      end

      # Auto-apply demands certainty: exact reference, exact amount, exact
      # currency, against exactly one still-open session. Anything else queues.
      def matching_session(transfer)
        return nil if transfer.reference_normalized.blank?

        candidates = ::Spree::PaymentSessions::BankTransfer.open.where(
          payment_method_id: payment_method.id,
          external_id_normalized: transfer.reference_normalized
        )

        return nil unless candidates.count == 1

        session = candidates.first
        return nil unless session.amount == transfer.amount
        return nil unless session.currency == transfer.currency

        # Advisory: only compare when both sides recorded an account. A legacy
        # session, or the Manual reconciler, has none and matches as before.
        if session.bank_account_id.present? && transfer.bank_account_id.present? &&
           session.bank_account_id != transfer.bank_account_id
          return nil
        end

        # C2: the customer may have abandoned the transfer, paid by card, and
        # then sent the bank transfer anyway from the emailed instructions --
        # it would exact-match the still-open session and auto-apply a *second*
        # payment, leaving the order in credit_owed with real money to refund.
        # A second payment on a settled order is a human decision, so this
        # queues for the hand-match screen instead of applying itself.
        return nil if %w[paid credit_owed].include?(session.order&.payment_state)

        session
      end
    end
  end
end
