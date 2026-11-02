require 'spec_helper'

# The transfer is matched on its exact amount, so what the buyer is told to
# pay, the pending payment and the order total must stay equal however the
# cart changes after bank transfer was chosen.
RSpec.describe 'Requoting a bank transfer session' do
  let(:gateway) { create(:bank_transfer_gateway).tap { |g| g.update!(preferred_discount_percent: 0) } }
  let(:cart) { bank_transfer_cart(gateway: gateway, price: 100) }
  let!(:session) { gateway.create_payment_session(order: cart) }
  let(:original_reference) { session.reference }

  def add_item(price)
    create(:line_item, cart: cart, order: nil, price: price)
    cart.line_items.reload
    cart.recalculate_totals!
  end

  it 'requotes when the cart grows after the buyer chose bank transfer' do
    add_item(50)
    gateway.complete_payment_session(payment_session: session)

    expect(cart.payments.last.amount).to eq(BigDecimal('150.00'))
  end

  it 'keeps the reference when it requotes' do
    original_reference
    add_item(50)
    gateway.complete_payment_session(payment_session: session)

    expect(session.reload.reference).to eq(original_reference)
  end

  it 'requotes the session itself' do
    add_item(50)
    gateway.update_payment_session(payment_session: session)

    expect(session.reload.amount).to eq(BigDecimal('150.00'))
  end

  # The buyer completed the session, went back, changed the cart and
  # completed it again: the pending payment must follow.
  it 'resizes the pending payment when a completed session is completed again' do
    gateway.complete_payment_session(payment_session: session)
    add_item(50)
    gateway.complete_payment_session(payment_session: session)

    expect(cart.payments.last.amount).to eq(BigDecimal('150.00'))
  end
end
