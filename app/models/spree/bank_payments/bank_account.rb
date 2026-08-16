module Spree
  module BankPayments
    # One account money can arrive in. `offered` decides whether customers are
    # quoted it; every active account is watched regardless, which is what makes
    # switching accounts safe for orders already in flight.
    class BankAccount < Base
      # Spree::PaymentMethod (our belongs_to parent) is acts_as_paranoid.
      # Without this, Gateway's `dependent: :destroy` on #bank_accounts would
      # hard-delete these rows the moment an admin soft-deletes the gateway --
      # restoring the gateway a day later would not bring the coordinates
      # back. Spree::PaymentSession is paranoid for the same reason.
      acts_as_paranoid

      belongs_to :payment_method, class_name: 'Spree::PaymentMethod'

      validates :currency, presence: true, format: { with: /\A[A-Za-z]{3}\z/ }
      # Mirrors index_bp_bank_accounts_on_pm_and_currency_offered exactly
      # (payment_method_id + currency, where offered AND deleted_at IS NULL --
      # acts_as_paranoid's default scope already excludes soft-deleted rows
      # from this uniqueness check). The database index is the real
      # guarantee; this validation exists only so an admin offering a second
      # account for a currency they already offer sees a form error instead
      # of an unrescued RecordNotUnique.
      validates :currency,
                uniqueness: { scope: :payment_method_id, conditions: -> { where(offered: true) },
                              message: 'already has an offered account for this currency' },
                if: :offered?
      validate :has_a_usable_detail_set

      scope :offered, -> { where(offered: true) }
      scope :active,  -> { where(active: true) }
      scope :for_currency, ->(code) { where(currency: code.to_s.upcase) }

      before_validation :normalize_currency

      # @return [Array<Spree::BankPayments::DetailSet>]
      def detail_sets
        Array(details).map { |raw| DetailSet.new(raw) }
      end

      def synced?
        provider_account_id.present?
      end

      private

      def normalize_currency
        self.currency = currency.to_s.upcase.presence
      end

      # An account with no payable coordinates is worse than no account: the
      # customer is quoted an empty instruction block and has nowhere to send
      # money.
      def has_a_usable_detail_set
        return if detail_sets.any?(&:usable?)

        errors.add(:details, :blank)
      end
    end
  end
end
