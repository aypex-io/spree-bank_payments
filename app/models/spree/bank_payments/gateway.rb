module Spree
  module BankPayments
    class Gateway < ::Spree::PaymentMethod
      preference :reconciler, :string, default: 'manual'
      preference :reference_prefix, :string, default: ''
      preference :expiry_days, :integer, default: 3
      preference :discount_percent, :decimal, default: 0
      preference :poll_interval_minutes, :integer, default: 15

      preference :account_name, :string
      preference :account_iban, :string
      preference :account_bic, :string
      preference :account_sort_code, :string
      preference :account_number, :string

      validate :discount_percent_within_bounds
      validate :expiry_days_positive
      validate :reconciler_registered

      has_many :bank_accounts,
               class_name: 'Spree::BankPayments::BankAccount',
               foreign_key: :payment_method_id,
               dependent: :destroy

      def payment_source_class
        nil
      end

      def source_required?
        false
      end

      def payment_session_class
        ::Spree::PaymentSessions::BankTransfer
      end

      def create_payment_session(order:, amount: nil, external_data: {})
        # The quoted amount must already reflect the discount. The Payment
        # after_create hook cannot be relied on here: in this gem the payment
        # is often not created until reconciliation (Task 6's
        # find_or_create_payment!), which would quote the customer the
        # undiscounted total and then move the goalposts once funds arrive.
        # ApplyDiscount is idempotent, so the later reconciliation-time hook
        # becomes a harmless no-op rather than a second discount.
        ApplyDiscount.call(order: order, payment_method: self)

        account = offered_account_for(order.currency)

        session = ::Spree::PaymentSessions::BankTransfer.create!(
          order: order,
          payment_method: self,
          amount: amount || order.total_minus_store_credits,
          currency: order.currency,
          external_id: ReferenceGenerator.new(payment_method: self).generate,
          external_data: external_data,
          expires_at: preferred_expiry_days.to_i.days.from_now,
          bank_account_id: account&.id
        )

        Spree::Events.publish('bank_transfer.instructions_ready', session.notification_payload)

        session
      end

      def auto_capture?
        false
      end

      # Money moves when the reconciler confirms it, never on an admin's click
      # in the payments screen. Void remains available for abandoning an order.
      def actions
        %w[void]
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

      # Spree::PaymentMethod#method_type defaults to `type.demodulize.downcase`
      # ("gateway" for this class), which is what spree_storefront uses to look
      # up "spree/checkout/payment/#{method_type}" -- without this override the
      # checkout partial is never found in a real store, even though it renders
      # fine when a spec renders it by explicit path.
      def method_type
        'spree_bank_payments'
      end

      def description_partial_name
        'spree_bank_payments'
      end

      def configuration_guide_partial_name
        'spree_bank_payments'
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

      # Called by Spree::Api::V3::Webhooks::PaymentsController. Signature
      # verification happens inside the reconciler and raises
      # Spree::PaymentMethod::WebhookSignatureError, which the controller turns
      # into a 401.
      def parse_webhook_event(raw_body, headers)
        data = reconciler.parse_webhook(raw_body, headers)
        return nil if data.nil?

        transfer = IngestTransfer.new(payment_method: self, transfer_data: data).call
        return nil unless transfer.applied?

        {
          action: :captured,
          payment_session: transfer.payment_session,
          metadata: { incoming_transfer_id: transfer.id }
        }
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

      # @deprecated Use #bank_details_for(currency).
      def bank_details
        message =
          'Spree::BankPayments::Gateway#bank_details is deprecated; ' \
          'use #bank_details_for(currency).'

        if defined?(Spree::Deprecation)
          Spree::Deprecation.warn(message)
        else
          Rails.logger.warn(message)
        end

        bank_details_for(Spree::Config[:currency])
      end

      # Strip a trailing .0 on whole numbers (3 -> "3") but keep fractional
      # precision (2.5 -> "2.5") -- percent.to_i would silently round 2.5% down
      # to "2%" in customer-facing copy. Shared by ApplyDiscount's adjustment
      # label and the checkout/instructions partials so no caller reintroduces
      # the truncation bug.
      def formatted_discount_percent
        percent = preferred_discount_percent.to_d
        percent == percent.to_i ? percent.to_i.to_s : percent.to_s('F')
      end

      private

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
