module Spree
  module BankPayments
    class IncomingTransfer < Base
      STATES = %w[unmatched applied ignored].freeze

      # Crockford base32 decoding folds these ambiguous glyphs. Applied to both
      # sides of a comparison, so a customer typing O for 0 still matches.
      AMBIGUOUS = { 'O' => '0', 'I' => '1', 'L' => '1' }.freeze

      belongs_to :payment_session, class_name: 'Spree::PaymentSession', optional: true
      belongs_to :applied_by, class_name: Spree.admin_user_class.to_s, optional: true
      # Nullable: older/manually-created transfers may not know their gateway.
      # Set by IngestTransfer on creation; used to keep the admin hand-match
      # queue from applying a transfer received on one bank-transfer gateway
      # to a session belonging to a different one.
      belongs_to :payment_method, class_name: 'Spree::PaymentMethod', optional: true
      belongs_to :bank_account,
                 class_name: 'Spree::BankPayments::BankAccount',
                 optional: true

      validates :provider, :provider_transaction_id, :amount, :currency, :occurred_at, presence: true
      validates :provider_transaction_id, uniqueness: { scope: :provider }
      validates :state, inclusion: { in: STATES }

      scope :unmatched, -> { where(state: 'unmatched') }
      scope :applied,   -> { where(state: 'applied') }

      before_validation :normalize_stored_reference

      def self.normalize_reference(value)
        value.to_s.upcase.gsub(/[^A-Z0-9]/, '').gsub(/[OIL]/, AMBIGUOUS)
      end

      STATES.each do |state_name|
        define_method("#{state_name}?") { state == state_name }
      end

      def money
        Spree::Money.new(amount, currency: currency)
      end

      private

      def normalize_stored_reference
        self.reference_normalized = self.class.normalize_reference(reference_raw)
      end
    end
  end
end
