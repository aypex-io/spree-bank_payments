module Spree
  module BankPayments
    class Gateway < ::Spree::PaymentMethod
      # Amounts arrive as Spree::Money (amount and currency), not hundredths.
      self.accepts_money_amounts = true

      # Deliberately a plain string with a registry validation, not `choices:`.
      # Spree enforces choices on every Admin API write of the preferences,
      # and the dashboard sends them all, so a gateway whose provider gem has
      # been uninstalled could no longer be deactivated -- the recovery
      # #reconciler_registered exists to keep open.
      preference :reconciler, :string, default: 'manual'
      preference :reference_prefix, :string, default: ''
      preference :expiry_days, :integer, default: 3
      preference :discount_percent, :decimal, default: 0
      preference :poll_interval_minutes, :integer, default: 15

      # The single-account preferences 5.2.0 replaced with BankAccount records.
      # Still declared so migration 20260817000004 can read what a 5.1 store
      # stored, and internal so the dashboard never offers them.
      preference :account_name, :string, internal: true
      preference :account_iban, :string, internal: true
      preference :account_bic, :string, internal: true
      preference :account_sort_code, :string, internal: true
      preference :account_number, :string, internal: true

      validate :discount_percent_within_bounds
      validate :expiry_days_positive
      validate :reconciler_registered

      has_many :bank_accounts,
               class_name: 'Spree::BankPayments::BankAccount',
               foreign_key: :payment_method_id,
               dependent: :destroy

      # The type the Store and Admin APIs send, and the suffix of the
      # dashboard's payment-method slots. Without it Spree would derive
      # "gateway" from the class's leaf name.
      def self.api_type
        'bank_transfer'
      end

      def self.display_name
        I18n.t('spree.bank_payments.gateway_name')
      end

      def self.description
        I18n.t('spree.bank_payments.gateway_description')
      end

      def payment_source_class
        nil
      end

      # The storefront creates a session when the buyer picks bank transfer
      # (the quote) and completes it when they place the order. Spree's
      # direct-payment endpoint refuses session-required methods.
      def session_required?
        true
      end

      # Pinned, whatever the store or this record says. A pending payment on a
      # method that defers capture counts as ready to ship
      # (Spree::Fulfillments::Fulfill#ensure_ready_to_hand_over); capturing "at
      # checkout" keeps an unpaid bank transfer order held until it is paid,
      # and stops dispatch from trying to capture money that has not arrived.
      def resolved_capture_method
        'checkout'
      end

      def source_required?
        false
      end

      def payment_session_class
        ::Spree::PaymentSessions::BankTransfer
      end

      # Quotes a bank transfer when the buyer picks it: a fresh reference, the
      # amount due and the bank details to pay into. Any earlier open bank
      # transfer session on the purchase is released first, so only one
      # reference is ever live per purchase.
      #
      # The caller's amount is ignored: the quote is what a transfer will be
      # matched against, so it is always computed here, after the discount.
      # Instructions are not sent yet; that happens when the order is placed.
      #
      # @param order [Spree::Cart, Spree::Order] the purchase (a cart during
      #   checkout; Spree's argument name predates the split)
      # @param external_data [Hash] client data, kept apart from the quote
      # @return [Spree::PaymentSessions::BankTransfer] unsaved, with errors,
      #   when it is invalid
      def create_payment_session(order:, amount: nil, external_data: {})
        purchase = order
        ReleaseSelection.call(purchase: purchase)

        session = payment_session_class.new(
          owner: purchase,
          payment_method: self,
          amount: purchase.amount_due_at_checkout,
          currency: purchase.currency,
          external_id: ReferenceGenerator.new(payment_method: self).generate,
          external_data: client_data(external_data),
          expires_at: preferred_expiry_days.to_i.days.from_now,
          bank_account_id: offered_account_for(purchase.currency)&.id
        )
        return session unless session.save

        Spree::BankPayments.recalculate!(purchase)
        session.requote!
        session
      end

      # Re-quotes the session against the purchase as it is now, keeping its
      # reference. The client's quote is never stored.
      #
      # @return [Spree::PaymentSessions::BankTransfer]
      def update_payment_session(payment_session:, amount: nil, external_data: {})
        payment_session.external_data = payment_session.external_data.to_h.merge(client_data(external_data))
        Spree::BankPayments.recalculate!(payment_session.owner)
        payment_session.requote!
        payment_session
      end

      # The buyer is placing the order. Re-quotes, then leaves a pending
      # payment keyed by the reference, which covers the purchase so Spree
      # places it unpaid. The session stays open (processing) until a transfer
      # is applied to it.
      #
      # Must not complete the purchase: Carts::Complete does that.
      #
      # @return [Spree::PaymentSessions::BankTransfer]
      def complete_payment_session(payment_session:, params: {})
        Spree::BankPayments.recalculate!(payment_session.owner)
        payment_session.requote!
        payment_session.process if payment_session.pending?

        payment = payment_session.settle_payment!(captured: false)
        resize_unsettled(payment, payment_session.amount)
        payment_session
      end

      # Spree retires the sessions an order left unused when it is placed. A
      # session that carries the order's payment is never unused.
      #
      # @return [Boolean] whether the session was canceled
      def cancel_payment_session(payment_session:)
        # Reloaded: settlement creates the payment through the owner, so a
        # session instance that looked before then still caches "none".
        return false if payment_session.reload_payment.present?

        payment_session.cancel
      end

      # Money moves when the reconciler confirms it, never on an admin's click
      # in the payments screen. Void remains available for abandoning an order.
      def actions
        %w[void]
      end

      # Spree's checkout processing calls these for a payment it has to take
      # at completion. A bank transfer is never taken that way: the payment
      # exists only through a payment session, and is paid when the
      # reconciler sees the money.
      def authorize(*)
        refuse_outside_session
      end

      def purchase(*)
        refuse_outside_session
      end

      # Called only by ApplyTransfer, through Spree's capture workflow, once
      # the reconciler has already seen the money arrive. There is nobody to
      # ask, so it confirms.
      def capture(_amount, response_code, _gateway_options = {})
        ::Spree::PaymentResponse.new(true, '', {}, { authorization: response_code })
      end

      def can_void?(payment)
        payment.state != 'void'
      end

      def void(*)
        ::Spree::PaymentResponse.new(true, '', {}, {})
      end

      def cancel(*)
        ::Spree::PaymentResponse.new(true, '', {}, {})
      end

      # Memoized because #health calls it twice and #health runs on every
      # checkout render for a non-Manual gateway -- unmemoized that was two
      # round trips per render, and on a gateway that has never polled, two
      # find_or_create_by! calls.
      def reconciler_state
        @reconciler_state ||= find_or_create_reconciler_state
      end

      def reconciler
        @reconciler ||= Reconcilers::Base.build(payment_method: self)
      end

      # Memoized state must not outlive an explicit reload of the record.
      def reload(*)
        @reconciler_state = nil
        @reconciler = nil
        super
      end

      # Gate on both the reconciler's own opinion and our recorded poll history.
      # The Manual reconciler is always healthy because it never polls.
      #
      # An unbuildable reconciler is unhealthy rather than an exception. Two
      # callers make that matter: ExpireSessionsJob, which must not cancel
      # anything while we cannot see the bank, and the payment method's
      # configuration-guide partial, which Spree renders on the **edit form** --
      # so raising here locked an admin out of the one screen where an
      # uninstalled provider gem can be switched back to 'manual'.
      def reconciler_healthy?
        built = safely_built_reconciler
        return false if built.nil?
        return false unless built.healthy?
        return true if built.instance_of?(Reconcilers::Manual)

        reconciler_state.healthy?(preferred_poll_interval_minutes)
      end

      # The persisted view of health, safe to call on the checkout hot path.
      #
      # Deliberately does NOT call `reconciler.health`: available_for_order? runs
      # on every checkout render, and a provider's live check is an HTTP request.
      # The poll job is what refreshes this.
      #
      # #reconciler_healthy? is left alone -- it gates the expiry job from a
      # background worker where a live check is fine, and changing it here would
      # alter behaviour this task has no reason to touch.
      def health
        return :ok if manual_reconciler?

        persisted = reconciler_state.health_status.presence&.to_sym
        return :consent_revoked if persisted == :consent_revoked

        reconciler_state.healthy?(preferred_poll_interval_minutes) ? :ok : :transient
      end

      # Called by Spree's payments webhook endpoint. Signature verification
      # happens inside the reconciler, which raises
      # Spree::PaymentMethod::WebhookSignatureError for a 401.
      #
      # Always nil: the transfer is ingested and, on a certain match, applied
      # here, under this gem's matching rules. Handing a session back would
      # let Spree's webhook workflow settle it again, and complete the cart of
      # a session that was never placed.
      #
      # @return [nil]
      def parse_webhook_event(raw_body, headers)
        data = reconciler.parse_webhook(raw_body, headers)
        IngestTransfer.new(payment_method: self, transfer_data: data).call unless data.nil?
        nil
      end

      # The account customers are quoted for this currency. Only one can be
      # offered per currency -- guaranteed by a partial unique index.
      def offered_account_for(currency)
        bank_accounts.active.offered.for_currency(currency).first
      end

      # @return [Array<Spree::BankPayments::DetailSet>] every usable detail set,
      #   in order. The buyer is always shown all of them: they know where they
      #   bank, and inferring local-vs-international from billing country would
      #   need a maintained SEPA membership list and would hide the details the
      #   customer actually needed when it guessed wrong.
      def bank_details_for(currency)
        account = offered_account_for(currency)
        return [] if account.nil?

        account.detail_sets.select(&:usable?)
      end

      # @param order [Spree::Cart, Spree::Order] the purchase being paid for
      def available_for_order?(order)
        return false unless super

        # Nothing will ever reconcile against a dead consent, so quoting bank
        # details would take money we cannot match to an order. :transient is
        # deliberately not gated here.
        return false if health == :consent_revoked

        return true if offered_account_for(order.currency).present?

        # An order that already quoted this gateway must be able to settle
        # even if the merchant has since stopped offering every account in
        # its currency. Spree::Payment reuses this same predicate to gate
        # payment creation (`payment_method_available_for_order`), and a
        # transfer can arrive days after the quote -- long enough for an
        # admin to switch or retire accounts in between. Checkout listing is
        # unaffected: a brand-new order has no session yet, so this branch
        # never widens which methods a fresh checkout can select. Scoped to
        # the order's *current* currency: a cart quoted in GBP and then
        # switched to USD must not resurrect availability for a currency
        # that never had an offered account -- `bank_details_for('USD')`
        # would return an empty instructions block.
        order.payment_sessions.exists?(
          payment_method_id: id,
          type: payment_session_class.name,
          currency: order.currency
        )
      end

      # Publishes one of the operational bank_transfer events, under this
      # gateway's store (the jobs that publish them run with none). Declared
      # webhook: false, so no endpoint receives them.
      #
      # @param name [String] one of Spree::BankPayments::OPERATIONAL_EVENTS
      # @param payload [Hash] serializable primitives
      # @return [Spree::Event, nil]
      def publish_operational_event(name, payload)
        Spree::Current.with_store(store) do
          publish_event(name, payload.deep_stringify_keys)
        end
      end

      # Strip a trailing .0 on whole numbers (3 -> "3") but keep fractional
      # precision (2.5 -> "2.5") -- percent.to_i would silently round 2.5% down
      # to "2%" in customer-facing copy. Shared by the discount label, the
      # quote and the instructions emails, so none reintroduces the truncation.
      def formatted_discount_percent
        percent = preferred_discount_percent.to_d
        percent == percent.to_i ? percent.to_i.to_s : percent.to_s('F')
      end

      private

      # A completed session's payment is created once, for the amount quoted
      # then. A buyer who goes back, changes the cart and places the order
      # again must owe what the cart now totals.
      def resize_unsettled(payment, amount)
        return if payment.nil? || payment.amount == amount
        return unless %w[checkout pending].include?(payment.status)

        payment.update!(amount: amount)
      end

      def client_data(external_data)
        external_data.to_h.stringify_keys.except(Spree::PaymentSessions::BankTransfer::QUOTE_KEY)
      end

      def refuse_outside_session
        ::Spree::PaymentResponse.new(false, I18n.t('spree.bank_payments.errors.session_required'), {}, {})
      end

      # The first-ever concurrent checkout render on a gateway is a real race:
      # two requests both miss the SELECT, both INSERT, and the unique index on
      # payment_method_id makes the loser raise. PollJob already reasons about
      # this race (its rescue guards a nil `state`); the checkout path did not.
      # By the time the loser is here the winner has committed a row, so
      # re-reading it is the whole recovery.
      def find_or_create_reconciler_state
        Spree::BankPayments::ReconcilerState.find_or_create_by!(payment_method_id: id)
      rescue ActiveRecord::RecordNotUnique
        Spree::BankPayments::ReconcilerState.find_by!(payment_method_id: id)
      end

      # #health is reached from available_for_order?, which runs on every
      # checkout render for every customer. Reconcilers::Base.build raises for
      # a key that is not in the registry -- a typo'd preference, or a provider
      # gem uninstalled while a gateway still names it -- and before 5.3.0 that
      # only ever surfaced inside PollJob and ExpireSessionsJob, both of which
      # rescue per payment method. Letting it escape here would turn a config
      # mistake into a storefront 500.
      #
      # An unbuildable reconciler is therefore simply "not the Manual one", so
      # #health falls through to the persisted state and reads :transient for a
      # gateway that has never polled: the payment method keeps being offered
      # and nothing reconciles, which is exactly what a misconfigured gateway
      # did before this release. Withdrawing checkout on a config typo would be
      # a new and much louder failure mode than the one being fixed.
      def manual_reconciler?
        safely_built_reconciler.instance_of?(Reconcilers::Manual)
      end

      # The rescue is deliberately tight around the build itself, and catches
      # only ArgumentError -- the one Reconcilers::Base.build raises for an
      # unregistered key. A provider's own constructor blowing up is a bug that
      # should still surface, not something to fold into "unhealthy".
      def safely_built_reconciler
        reconciler
      rescue ArgumentError
        nil
      end

      # Catch the typo where it is made, rather than at the next poll. Skipped
      # when the value is unchanged on an already-persisted record: if a
      # provider gem is uninstalled, an admin still has to be able to save this
      # gateway -- deactivating it, or switching it back to 'manual', is the
      # recovery, and a validation that refused every save would lock the one
      # record they need to fix.
      #
      # Saving is only half of that recovery: the admin also has to be able to
      # *open* the edit form, whose configuration-guide partial calls
      # #reconciler_healthy?. That is why that method tolerates an unbuildable
      # reconciler too -- without it this escape hatch would let an admin save a
      # screen they could never reach.
      def reconciler_registered
        key = preferred_reconciler.to_s
        return if Reconcilers::Base.registry.key?(key)
        return if persisted? && persisted_reconciler_key == key

        errors.add(:preferred_reconciler, :inclusion)
      end

      def persisted_reconciler_key
        (preferences_in_database || {}).with_indifferent_access[:reconciler].to_s
      end

      def discount_percent_within_bounds
        percent = preferred_discount_percent.to_d
        return if percent >= 0 && percent <= 100

        errors.add(:preferred_discount_percent, :inclusion)
      end

      def expiry_days_positive
        return if preferred_expiry_days.to_i.positive?

        errors.add(:preferred_expiry_days, :greater_than, count: 0)
      end
    end
  end
end
