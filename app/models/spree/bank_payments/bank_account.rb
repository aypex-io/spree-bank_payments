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
      validate :details_is_a_list_of_objects
      validate :has_a_usable_detail_set

      scope :offered, -> { where(offered: true) }
      scope :active,  -> { where(active: true) }
      scope :for_currency, ->(code) { where(currency: code.to_s.upcase) }

      before_validation :normalize_currency

      # @return [Array<Spree::BankPayments::DetailSet>] one per *object* entry.
      #   Non-object entries are skipped rather than raising: `details` is
      #   admin-editable JSON, and `Array(a_hash)` yields `[[key, value]]`, so
      #   an admin pasting `{"label": ...}` where an array belongs used to blow
      #   up with NoMethodError inside a validation. #details_is_a_list_of_objects
      #   turns that into a form error instead.
      def detail_sets
        Array(details).grep(Hash).map { |raw| DetailSet.new(raw) }
      end

      def synced?
        provider_account_id.present?
      end

      private

      def normalize_currency
        self.currency = currency.to_s.upcase.presence
      end

      # `details` is a JSON array of detail-set objects. Anything else is a
      # form error, not an exception: the admin form takes raw JSON, so a
      # pasted object (`{"label": ...}`) or a bare scalar is an ordinary typo.
      def details_is_a_list_of_objects
        return if details.nil?
        return if details.is_a?(Array) && details.all?(Hash)

        errors.add(:details, 'must be a JSON array of detail set objects')
      end

      # An account with no payable coordinates is worse than no account: the
      # customer is quoted an empty instruction block and has nowhere to send
      # money.
      def has_a_usable_detail_set
        # Shape already reported; a second error about the same field only
        # obscures the actual problem.
        return if errors.key?(:details)
        return if detail_sets.any?(&:usable?)

        errors.add(:details, :blank)
      end
    end
  end
end
