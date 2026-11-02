module Spree
  module BankPayments
    # Takes an unmatched transfer out of the queue, with the reason staff
    # give for it: refunded to the payer, a test payment, a duplicate.
    class IgnoreTransfer
      include ActiveModel::Model
      include ActiveModel::Validations

      attr_accessor :transfer, :reason

      validates :reason, presence: true

      # @return [Spree::BankPayments::IncomingTransfer]
      # @raise [ActiveModel::ValidationError] without a reason
      def self.call(transfer:, reason:)
        new(transfer: transfer, reason: reason.to_s.strip).call
      end

      def call
        validate!
        transfer.update!(state: 'ignored', ignored_reason: reason)
        transfer
      end
    end
  end
end
