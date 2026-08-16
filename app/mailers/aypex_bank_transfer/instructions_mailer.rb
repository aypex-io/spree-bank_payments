module AypexBankTransfer
  class InstructionsMailer < ApplicationMailer
    def instructions(payment_session_id)
      @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
      @order = @session.order
      @bank_details = @session.payment_method.bank_details

      mail(to: @order.email, subject: Spree.t('bank_transfer.reference'))
    end

    def reminder(payment_session_id)
      @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
      @order = @session.order
      @bank_details = @session.payment_method.bank_details

      mail(to: @order.email, subject: Spree.t('bank_transfer.pay_within', days: 2))
    end
  end
end
