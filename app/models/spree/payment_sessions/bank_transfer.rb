module Spree
  module PaymentSessions
    class BankTransfer < Spree::PaymentSession
      # `-> { with_deleted }`: BankAccount is acts_as_paranoid, and without
      # this a soft-deleted account (an admin decision, see the destroy
      # action) resolves to nil here -- silently blanking the coordinates an
      # open session already quoted the customer. Soft-delete instead of
      # hard-delete exists precisely so that quote survives; this scope is
      # what actually keeps that promise.
      belongs_to :bank_account,
                 -> { with_deleted },
                 class_name: 'Spree::BankPayments::BankAccount',
                 optional: true

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

      # The coordinates this session was actually quoted against -- the single
      # source of truth for every customer-facing surface (the instructions
      # partial and both InstructionsMailer actions).
      #
      # Reading `payment_method.bank_details_for(currency)` here instead would
      # render whatever account is offered *now*, not what the customer was
      # told: switch the offered GBP account from A to B and every open
      # session's reminder starts quoting B's coordinates against a reference
      # generated for A, sending the money to the wrong account. Un-offer the
      # currency entirely and the block renders empty -- a reference, an
      # amount, a deadline, and nowhere to send it. `bank_account` is scoped
      # `-> { with_deleted }` precisely so a soft-deleted account still
      # resolves here.
      #
      # The fallback covers the two cases with no recorded account: sessions
      # created before 5.2.0, and reconcilers (e.g. Manual) running against a
      # gateway whose account was never linked.
      #
      # @return [Array<Spree::BankPayments::DetailSet>]
      def bank_detail_sets
        return payment_method.bank_details_for(currency) if bank_account.nil?

        bank_account.detail_sets.select(&:usable?)
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
          Spree::BankPayments::IncomingTransfer.normalize_reference(external_id)
      end
    end
  end
end
