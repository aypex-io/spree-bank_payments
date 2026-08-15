module Spree
  module PaymentSessions
    class BankTransfer < Spree::PaymentSession
      before_validation :normalize_external_id

      scope :open, -> { where(status: %w[pending processing]) }

      def expired?
        expires_at.present? && expires_at <= Time.current
      end

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
          AypexBankTransfer::IncomingTransfer.normalize_reference(external_id)
      end
    end
  end
end
