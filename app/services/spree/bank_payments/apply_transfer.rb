module Spree
  module BankPayments
    # The single place money actually moves. IngestTransfer calls this with no
    # `applied_by` for automatic application; the staff hand-match queue calls
    # it with the acting admin. One transaction, one path: no second
    # implementation of what applying a transfer means.
    #
    # The payment is settled through Spree's capture workflow, so Spree records
    # the capture, publishes payment.captured and recomputes the order's
    # statuses as it does for any gateway. The gateway's capture only
    # confirms: the reconciler has already seen the money.
    class ApplyTransfer
      # Applying was refused: the session's cart was never placed, or Spree's
      # capture workflow declined.
      class Refused < StandardError; end

      # The transfer was already applied: a double click, or two staff at
      # once. A Refused, so IngestTransfer's replay handling is unchanged.
      class AlreadyApplied < Refused; end

      UNSETTLED_PAYMENT_STATUSES = %w[checkout pending].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(transfer:, payment_session:, applied_by: nil)
        @transfer = transfer
        @payment_session = payment_session
        @applied_by = applied_by
      end

      # @return [Spree::BankPayments::IncomingTransfer]
      # @raise [AlreadyApplied] the transfer is applied already
      # @raise [Refused] the order is not placed or not payable, or Spree's
      #   capture workflow declined
      def call
        order = payment_session.order
        raise Refused, I18n.t('spree.bank_payments.errors.order_not_placed') if order.nil?

        ActiveRecord::Base.transaction do
          order.with_lock do
            # Lock the transfer too, then re-read it: two requests applying
            # one transfer to different orders hold different order locks, so
            # only this one makes the second wait and then refuse. Always
            # order before transfer, so the two locks never deadlock.
            transfer.lock!
            raise AlreadyApplied, I18n.t('spree.bank_payments.errors.already_applied') if transfer.applied?

            ensure_payable!(order)
            payment = payment_session.reload_payment || payment_session.find_or_create_payment!
            raise Refused, I18n.t('spree.bank_payments.errors.session_already_paid') if payment.completed?

            restamp(payment)
            capture(payment)
            # After the payment, so a session.completed event (plausibly a
            # receipt) can never go out for a payment that did not settle.
            payment_session.complete
            transfer.update!(applied_attributes)
          end
        end

        transfer
      end

      private

      attr_reader :transfer, :payment_session, :applied_by

      # On the automatic path the transfer matched the quote exactly, so this
      # changes nothing. Staff can apply a transfer that differs from it;
      # crediting the quote would mark the order paid for money that never
      # arrived. A settled payment is never touched.
      def restamp(payment)
        return unless UNSETTLED_PAYMENT_STATUSES.include?(payment.status)
        return if payment.amount == transfer.amount

        payment.update!(amount: transfer.amount)
      end

      def ensure_payable!(order)
        raise Refused, I18n.t('spree.bank_payments.errors.order_not_placed') unless order.placed?
        return if payment_session.reload.pending? || payment_session.processing?

        raise Refused, I18n.t('spree.bank_payments.errors.session_already_paid')
      end

      # The one capture of a bank transfer payment GuardCapture lets through.
      def capture(payment)
        result = Spree::BankPayments::Current.set(applying_transfer: true) do
          Spree.payment_capture_workflow.call(payment: payment)
        end
        raise Refused, result.error.to_s unless result.success?
      end

      def applied_attributes
        attributes = { state: 'applied', payment_session: payment_session }
        return attributes unless applied_by

        attributes.merge(applied_by_id: applied_by.id, applied_at: Time.current)
      end
    end
  end
end
