module Spree
  module BankPayments
    # The single place money actually moves. IngestTransfer calls this with no
    # `applied_by` for automatic application; the admin hand-match queue
    # (Task 13) calls it with the acting admin user. One transaction, one path
    # — no second implementation of "what applying a transfer means".
    class ApplyTransfer
      def self.call(...)
        new(...).call
      end

      def initialize(transfer:, payment_session:, applied_by: nil)
        @transfer = transfer
        @payment_session = payment_session
        @applied_by = applied_by
      end

      def call
        ActiveRecord::Base.transaction do
          # Payment completes before the session. Spree::PaymentSession uses
          # publishes_lifecycle_events, which publishes synchronously inside
          # this transaction — completing the session first would let a
          # "session completed" event (plausibly a customer receipt) escape
          # before we know the payment itself will actually complete. If
          # payment.complete! raises, the DB rolls back but that event
          # cannot be recalled.
          payment = payment_session.find_or_create_payment!

          # find_or_create_payment! (Spree core) stamps the *session's*
          # amount onto the payment -- correct on the automatic path, where
          # IngestTransfer only ever gets here on an exact amount/currency
          # match, so this is a no-op there. On the manual admin path (Task
          # 13) an admin can confirm applying a transfer to a session whose
          # amount doesn't match what actually arrived; crediting the
          # session's amount in that case would mark the order 'paid' for
          # money it never received. Re-stamp the payment with what the
          # transfer says actually arrived before completing it, so Spree's
          # own payment_state computation reflects the real balance
          # (balance_due/credit_owed) instead of a false 'paid'.
          #
          # Only mutate while the payment is still editable (pre-completion):
          # Payment#editable? is checkout/pending, and completing flips
          # payment_total via the state machine, so touching amount after
          # completion would need a second recalculation this class doesn't
          # own. `find_or_create_payment!` always returns either a payment it
          # just created (checkout state) or one it found by the same
          # response_code -- if that existing payment is already completed
          # (shouldn't happen: the `applied?` guard upstream prevents
          # re-applying), leave its amount alone rather than mutate a
          # finalized record.
          if !payment.completed? && payment.amount != transfer.amount
            payment.update!(amount: transfer.amount)
          end

          payment.complete! unless payment.completed?
          payment_session.complete! unless payment_session.completed?

          attrs = { state: 'applied', payment_session: payment_session }
          if applied_by
            attrs[:applied_by_id] = applied_by.id
            attrs[:applied_at] = Time.current
          end

          transfer.update!(attrs)
        end

        transfer
      end

      private

      attr_reader :transfer, :payment_session, :applied_by
    end
  end
end
