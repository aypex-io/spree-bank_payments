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

      def reconciler_state
        Spree::BankPayments::ReconcilerState.find_or_create_by!(payment_method_id: id)
      end

      def reconciler
        @reconciler ||= Reconcilers::Base.build(payment_method: self)
      end

      # Gate on both the reconciler's own opinion and our recorded poll history.
      # The Manual reconciler is always healthy because it never polls.
      def reconciler_healthy?
        return false unless reconciler.healthy?
        return true if reconciler.instance_of?(Reconcilers::Manual)

        reconciler_state.healthy?(preferred_poll_interval_minutes)
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
