module Spree
  module BankPayments
    # What the Store API shows a storefront, added to Spree's own payment
    # method and payment serializers through Spree.api.extension_fields:
    #
    # - a payment method's `bank_transfer`: the discount and payment window to
    #   advertise before the buyer chooses (nil for other methods);
    # - a payment's `bank_transfer`: the reference, amount, deadline and bank
    #   details to pay into, on the cart and on the placed order, so a
    #   confirmation page can show the instructions (nil for other payments).
    #
    # Called once, from after_initialize. The values are read through
    # constants at request time, so they survive code reloads.
    def self.register_api_fields!
      fields = Spree.api.extension_fields

      fields.attribute(:payment_method_serializer, :bank_transfer, value: lambda { |payment_method|
        next unless payment_method.is_a?(Spree::BankPayments::Gateway)

        {
          'discount_percent' => payment_method.formatted_discount_percent,
          'expiry_days' => payment_method.preferred_expiry_days.to_i
        }
      })

      fields.attribute(:payment_serializer, :bank_transfer, value: lambda { |payment|
        next unless payment.payment_method.is_a?(Spree::BankPayments::Gateway)

        Spree::PaymentSessions::BankTransfer.
          find_by(payment_method_id: payment.payment_method_id, external_id: payment.response_code)&.
          quote
      })
    end
  end
end
