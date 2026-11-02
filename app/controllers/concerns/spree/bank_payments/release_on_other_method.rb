module Spree
  module BankPayments
    # Prepended onto the Store API's cart payment session and payment
    # controllers, the two places a storefront chooses a payment method.
    #
    # Both size the new session or payment from the cart total as it stands.
    # A buyer who picked bank transfer and then chose something else would be
    # charged the discounted total by the other method unless bank transfer
    # is released first, which cancels its session, voids its payment and
    # recalculates the discount away.
    module ReleaseOnOtherMethod
      def create
        release_bank_transfer_for_other_method
        super
      end

      private

      def release_bank_transfer_for_other_method
        return if @cart.nil?

        chosen = current_store.payment_methods.find_by_prefix_id(params[:payment_method_id])
        return if chosen.nil? || chosen.is_a?(Spree::BankPayments::Gateway)

        Spree::BankPayments::ReleaseSelection.call(purchase: @cart)
      end
    end
  end
end
