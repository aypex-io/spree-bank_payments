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
      # Creating another method's session or payment.
      def create
        release_bank_transfer_for(chosen_payment_method)
        super
      end

      # Updating or completing another method's session: one created before
      # bank transfer was chosen, which the buyer is paying through after all.
      def update
        release_bank_transfer_for(@payment_session&.payment_method)
        super
      end

      def complete
        release_bank_transfer_for(@payment_session&.payment_method)
        super
      end

      private

      def release_bank_transfer_for(payment_method)
        return if @cart.nil? || payment_method.nil?
        return if payment_method.is_a?(Spree::BankPayments::Gateway)

        Spree::BankPayments::ReleaseSelection.call(purchase: @cart)
      end

      # The method the request chooses, looked up as Spree's own action does,
      # or nil when Spree is about to refuse it: a request that changes
      # nothing must not release anything either.
      def chosen_payment_method
        payment_method = current_store.payment_methods.active.storefront_visible.
                         find_by_prefix_id(params[:payment_method_id])
        return if payment_method.nil? || !payment_method.available_for_order?(@cart)
        return if direct_payment? && payment_method.session_required?

        payment_method
      end

      def direct_payment?
        is_a?(Spree::Api::V3::Store::Carts::PaymentsController)
      end
    end
  end
end
