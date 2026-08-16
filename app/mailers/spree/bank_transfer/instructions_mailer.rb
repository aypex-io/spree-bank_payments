module Spree
  module BankTransfer
    class InstructionsMailer < Spree::BaseMailer
      def instructions(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
        @order = @session.order
        @bank_details = @session.payment_method.bank_details

        with_store_locale(@order.store) do
          mail(to: @order.email, subject: Spree.t('bank_transfer.reference'))
        end
      end

      def reminder(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
        @order = @session.order
        @bank_details = @session.payment_method.bank_details
        @days_remaining = ((@session.expires_at.to_date - Date.current).to_i)

        with_store_locale(@order.store) do
          mail(to: @order.email, subject: Spree.t('bank_transfer.pay_within', days: @days_remaining))
        end
      end

      def current_store
        @current_store ||= @order&.store
      end
    end
  end
end
