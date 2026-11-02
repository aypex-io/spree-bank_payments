module Spree
  module BankPayments
    # Registered on Spree's `payments.capture.validate` hook. A bank transfer
    # payment is captured only when a transfer is applied to it: a capture
    # from anywhere else (the dashboard's Capture action, the Admin API)
    # would mark the order paid with no money recorded and its session still
    # open. Spree's capture workflow turns the rejection into an error.
    class GuardCapture
      def call(flow)
        return unless flow.payment.payment_method.is_a?(Spree::BankPayments::Gateway)
        return if Spree::BankPayments::Current.applying_transfer

        flow.reject!(I18n.t('spree.bank_payments.errors.capture_only_by_transfer'))
      end
    end
  end
end
