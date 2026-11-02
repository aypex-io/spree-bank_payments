module Spree
  module PaymentSessions
    class BankTransfer < Spree::PaymentSession
      # Where the quote lives in external_data, which the Store API returns
      # whole. Clients may write their own keys; never this one.
      QUOTE_KEY = 'bank_transfer'.freeze
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

      # What the buyer is told to pay: the reference, the exact amount, the
      # deadline and the bank details.
      #
      # @return [Hash{String => Object}]
      def quote
        {
          'reference' => reference,
          'amount' => Spree::Money::Rounding.format(amount, currency),
          'currency' => currency,
          'expires_at' => expires_at&.iso8601,
          'discount_percent' => payment_method.formatted_discount_percent,
          'bank_details' => bank_detail_sets.map { |set| set.to_h.deep_stringify_keys }
        }
      end

      # Whether the instructions for this session have gone out. Spree can
      # replay order.placed, and one order is one set of instructions.
      def instructions_sent?
        external_data.to_h['instructions_sent_at'].present?
      end

      # Restarts the payment window from now, when the order is placed, and
      # records that the instructions are being sent. The quote's deadline
      # moves with it. A bookkeeping write, so no payment_session.updated.
      #
      # @return [void]
      def start_payment_window!
        self.expires_at = payment_method.preferred_expiry_days.to_i.days.from_now
        self.external_data = external_data.to_h.merge(
          'instructions_sent_at' => Time.current.iso8601,
          QUOTE_KEY => quote
        )

        Spree::Events.disable_lifecycle { save! }
      end

      # Re-reads the amount due from the owner and stores the quote. A
      # bookkeeping write, so it publishes no payment_session.updated.
      #
      # @return [void]
      def requote!
        self.amount = Spree::Money::Rounding.to_currency(owner.amount_due_at_checkout, currency)
        self.external_data = external_data.to_h.merge(QUOTE_KEY => quote)

        Spree::Events.disable_lifecycle { save! }
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

      # Everything a store needs to tell the buyer how to pay without a second
      # API call: webhook receivers that send their own email (a headless
      # storefront, say) get the bank details too.
      #
      # Event subscribers may run async via ActiveJob, so values are
      # serializable primitives, never records. Keys are strings because Spree
      # stringifies event payloads, and ids are prefixed because that is what
      # the APIs and webhooks speak.
      def notification_payload
        {
          'payment_session_id' => prefixed_id,
          'order_id' => order&.prefixed_id,
          'order_number' => order&.number,
          'order_email' => order&.email,
          'reference' => reference,
          'amount' => Spree::Money::Rounding.format(amount, currency),
          'currency' => currency,
          'expires_at' => expires_at&.iso8601,
          'discount_percent' => payment_method.formatted_discount_percent,
          'bank_details' => bank_detail_sets.map { |set| set.to_h.deep_stringify_keys }
        }
      end

      # Publishes one of the customer-facing bank_transfer events about this
      # session, under its gateway's store: Spree's webhook subscriber drops
      # an event with no store, and the jobs that publish these run with none.
      #
      # @param name [String] one of Spree::BankPayments::CUSTOMER_FACING_EVENTS
      # @return [Spree::Event, nil]
      def publish_bank_transfer_event(name)
        Spree::Current.with_store(payment_method.store) do
          publish_event(name, notification_payload)
        end
      end

      private

      def normalize_external_id
        self.external_id_normalized =
          Spree::BankPayments::IncomingTransfer.normalize_reference(external_id)
      end
    end
  end
end
