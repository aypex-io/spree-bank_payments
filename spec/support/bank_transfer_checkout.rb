# Drives a real Spree 6 checkout with the bank transfer gateway, the way a
# storefront does: create the session when the buyer picks bank transfer,
# complete it when they place the order, then complete the cart.
module BankTransferCheckout
  # A cart with addresses and a free delivery method, ready for payment, in a
  # currency the gateway offers an account for.
  def bank_transfer_cart(gateway:, price: 100, currency: 'USD')
    unless gateway.offered_account_for(currency)
      create(:bank_payments_bank_account, payment_method: gateway, currency: currency, offered: true)
    end

    create(:cart_ready_for_delivery, line_items_price: price, currency: currency, shipping_cost: 0)
  end

  # Puts the cart's items on the shelf, so its fulfillment can be handed
  # over rather than held as backordered.
  def stock!(cart, quantity: 10)
    cart.line_items.each do |line_item|
      Spree::StockLocation.order(:id).first.restock(line_item.variant, quantity)
    end
    cart.rebuild_fulfillments!
    cart.recalculate_totals!
    cart
  end

  # @return [Array(Spree::Order, Spree::PaymentSessions::BankTransfer)]
  def place_with_bank_transfer(cart, gateway:)
    session = gateway.create_payment_session(order: cart)
    gateway.complete_payment_session(payment_session: session)

    result = Spree.carts_complete_workflow.call(cart: cart)
    raise "cart did not complete: #{result.errors.full_messages.to_sentence}" unless result.success?

    [result.value, session.reload]
  end
end

RSpec.configure do |config|
  config.include BankTransferCheckout
  config.include ActiveSupport::Testing::TimeHelpers
end
