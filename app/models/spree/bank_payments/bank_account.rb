module Spree
  module BankPayments
    # One account money can arrive in. `offered` decides whether customers are
    # quoted it; every active account is watched regardless, which is what makes
    # switching accounts safe for orders already in flight.
    class BankAccount < Base
      belongs_to :payment_method, class_name: 'Spree::PaymentMethod'

      validates :currency, presence: true, format: { with: /\A[A-Za-z]{3}\z/ }
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
