module Spree
  module PaymentSessions
    class BankTransfer < Spree::PaymentSession
      before_validation :normalize_external_id

      # Deliberately matches on status alone, not `not_expired`/`active`.
      # Stock is released by the expiry job cancelling the session/order,
      # not by `expires_at` merely passing — so a transfer that arrives a
      # few minutes after `expires_at` but before that job runs is still
      # against a live, matchable session, and one that arrives after the
      # job runs finds the session already canceled and falls out of this
      # scope. Both orderings are safe. Restricting to `not_expired` here
      # would queue every payment that arrives even slightly late for a
      # human, manufacturing manual work for no correctness gain — do not
      # "fix" this into `active`.
      scope :open, -> { where(status: %w[pending processing]) }

      # NB: #expired? is deliberately NOT redefined here -- it was a
      # byte-identical copy of Spree::PaymentSession#expired?, which is
      # inherited.

      def reference
        external_id
      end

      # Event subscribers may run async via ActiveJob, so payloads must be
      # serializable primitives — never AR objects.
      def notification_payload
        {
          payment_session_id: id,
          order_number: order&.number,
          order_email: order&.email,
          reference: reference,
          amount: amount.to_s,
          currency: currency,
          expires_at: expires_at&.iso8601
        }
      end

      private

      def normalize_external_id
        self.external_id_normalized =
          SpreeBankTransfer::IncomingTransfer.normalize_reference(external_id)
      end
    end
  end
end
