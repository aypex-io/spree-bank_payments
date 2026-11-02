module Spree
  module BankPayments
    # Takes an unmatched transfer out of the queue, with the reason staff
    # give for it: refunded to the payer, a test payment, a duplicate.
    class IgnoreTransfer
      include ActiveModel::Model
      include ActiveModel::Validations

      # The transfer was applied, perhaps by a request that committed after
      # this one loaded it.
      class AlreadyApplied < StandardError; end

      attr_accessor :transfer, :reason

      validates :reason, presence: true

      # @return [Spree::BankPayments::IncomingTransfer]
      # @raise [ActiveModel::ValidationError] without a reason
      # @raise [AlreadyApplied] the transfer is applied
      def self.call(transfer:, reason:)
        new(transfer: transfer, reason: reason.to_s.strip).call
      end

      # Re-read under the transfer's lock, which ApplyTransfer also takes, so
      # a transfer is never ignored with a captured payment behind it.
      def call
        validate!
        transfer.with_lock do
          raise AlreadyApplied, I18n.t('spree.bank_payments.errors.already_applied') if transfer.applied?

          transfer.update!(state: 'ignored', ignored_reason: reason)
        end
        transfer
      end
    end
  end
end
