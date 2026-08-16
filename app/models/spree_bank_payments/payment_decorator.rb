module SpreeBankPayments
  module PaymentDecorator
    def self.prepended(base)
      base.after_create :sync_bank_transfer_discount
    end

    private

    # Called for every payment, not just bank transfer ones, so switching away
    # from bank transfer removes the discount rather than leaving it behind.
    def sync_bank_transfer_discount
      return if order.blank?

      SpreeBankPayments::ApplyDiscount.call(order: order, payment_method: payment_method)
    end
  end
end

Spree::Payment.prepend(SpreeBankPayments::PaymentDecorator) unless
  Spree::Payment.included_modules.include?(SpreeBankPayments::PaymentDecorator)
