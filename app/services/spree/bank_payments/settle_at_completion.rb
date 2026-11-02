module Spree
  module BankPayments
    # Registered on Spree's `carts.complete.validate` hook, which runs under
    # the cart's lock right after Carts::Complete recalculates it. Whatever
    # changed since the buyer completed the bank transfer session, the order
    # is placed owing exactly what they were quoted:
    #
    # - the bank transfer session the buyer completed (processing) is
    #   re-quoted and its pending payment resized to the cart as it stands;
    # - any other open bank transfer session (one the buyer never completed)
    #   is released, so a discount bank transfer is not paying comes off. If
    #   another payment was sized against that discount, the cart is left
    #   short and Spree refuses to place it.
    class SettleAtCompletion
      def call(flow)
        purchase = flow.cart
        sessions = open_sessions(purchase)
        return if sessions.empty?

        kept = sessions.find(&:processing?)
        Spree::BankPayments::ReleaseSelection.call(purchase: purchase, except: kept) if sessions.any? { |s| s != kept }
        kept&.payment_method&.requote!(kept.reload)
      end

      private

      def open_sessions(purchase)
        Spree::PaymentSessions::BankTransfer.open.
          where(id: purchase.payment_sessions.select(:id)).
          order(created_at: :desc, id: :desc).
          to_a
      end
    end
  end
end
