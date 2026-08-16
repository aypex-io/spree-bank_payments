module Spree
  module BankPayments
    class InstructionsMailer < Spree::BaseMailer
      def instructions(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
        @order = @session.order
        @detail_sets = @session.payment_method.bank_details_for(@session.currency)

        with_store_locale(@order.store) do
          mail(to: @order.email, subject: Spree.t('bank_payments.reference'))
        end
      end

      def reminder(payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
        @order = @session.order
        @detail_sets = @session.payment_method.bank_details_for(@session.currency)
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
