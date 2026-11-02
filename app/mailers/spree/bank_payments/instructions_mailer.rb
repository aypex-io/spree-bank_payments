module Spree
  module BankPayments
    class InstructionsMailer < Spree::BaseMailer
      # @param payment_session_id [String] the session's prefixed id, as event
      #   payloads carry it
      def instructions(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find_by_prefix_id!(payment_session_id)
        @order = @session.order
        @detail_sets = @session.bank_detail_sets

        with_store_locale(@order.store) do
          mail(to: @order.email, subject: Spree.t('bank_payments.reference'))
        end
      end

      # @param payment_session_id [String] the session's prefixed id
      def reminder(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find_by_prefix_id!(payment_session_id)
        @order = @session.order
        @detail_sets = @session.bank_detail_sets
        @days_remaining = ((@session.expires_at.to_date - Date.current).to_i)

        with_store_locale(@order.store) do
          mail(to: @order.email, subject: Spree.t('bank_payments.pay_within', days: @days_remaining))
        end
      end

      def current_store
        @current_store ||= @order&.store
      end
    end
  end
end
