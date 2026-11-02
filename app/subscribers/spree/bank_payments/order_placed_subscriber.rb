module Spree
  module BankPayments
    # Sends the payment instructions once the order exists. Until placement
    # the session belongs to a cart: no order number, often no email.
    #
    # Each bank transfer session the order is paying through (processing:
    # completed by the buyer, with a pending payment) gets its payment window
    # restarted from now, so the buyer has the full expiry_days, and then
    # publishes bank_transfer.instructions_ready, once. Spree can replay
    # order.placed, so the window and the instructions are each guarded.
    #
    # Synchronous, like Spree's own order.placed subscriber: the window must
    # be right before anything reads it, and Spree contains a subscriber's
    # errors, so placement cannot fail because of this.
    class OrderPlacedSubscriber < Spree::Subscriber
      subscribes_to 'order.placed', async: false

      def handle(event)
        order = Spree::Order.find_by_prefix_id(event.payload['id'])
        return if order.nil?

        Spree::PaymentSessions::BankTransfer.where(order: order, status: 'processing').find_each do |session|
          next if session.instructions_sent?

          session.start_payment_window!
          session.publish_bank_transfer_event('bank_transfer.instructions_ready')
        end
      end
    end
  end
end
