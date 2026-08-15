module AypexBankTransfer
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
      ::Spree::PaymentSessions::BankTransfer.create!(
        order: order,
        payment_method: self,
        amount: amount || order.total_minus_store_credits,
        currency: order.currency,
        external_id: ReferenceGenerator.new(payment_method: self).generate,
        external_data: external_data,
        expires_at: preferred_expiry_days.to_i.days.from_now
      )
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

    def description_partial_name
      'aypex_bank_transfer'
    end

    def configuration_guide_partial_name
      'aypex_bank_transfer'
    end

    def reconciler_state
      AypexBankTransfer::ReconcilerState.find_or_create_by!(payment_method_id: id)
    end

    def bank_details
      {
        account_name: preferred_account_name,
        iban: preferred_account_iban,
        bic: preferred_account_bic,
        sort_code: preferred_account_sort_code,
        account_number: preferred_account_number
      }
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
