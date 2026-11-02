require 'spec_helper'

RSpec.describe Spree::BankPayments::OrderPlacedSubscriber do
  let(:gateway) { create(:bank_transfer_gateway) } # 3 day window
  let(:cart) { bank_transfer_cart(gateway: gateway, price: 100) }

  before { capture_published_events }

  it 'publishes instructions once when the order is placed' do
    place_with_bank_transfer(cart, gateway: gateway)

    expect(published('bank_transfer.instructions_ready').size).to eq(1)
  end

  it 'addresses the instructions to the placed order' do
    order, = place_with_bank_transfer(cart, gateway: gateway)

    expect(published('bank_transfer.instructions_ready').first['order_number']).to eq(order.number)
  end

  # Spree may replay order.placed; one order is one set of instructions.
  it 'publishes them once when order.placed is replayed' do
    order, = place_with_bank_transfer(cart, gateway: gateway)

    described_class.new.handle(Spree::Event.new(name: 'order.placed', payload: { 'id' => order.prefixed_id }, store_id: order.store_id))

    expect(published('bank_transfer.instructions_ready').size).to eq(1)
  end

  it 'starts the payment window at placement' do
    travel_to(Time.zone.parse('2026-11-02 12:00')) do
      session = gateway.create_payment_session(order: cart)

      travel 2.days
      gateway.complete_payment_session(payment_session: session)
      Spree.carts_complete_workflow.call(cart: cart)

      expect(session.reload.expires_at).to eq(Time.zone.parse('2026-11-07 12:00'))
    end
  end

  it 'publishes nothing for an order paid another way' do
    paid_cart = create(:cart_ready_to_complete)

    Spree.carts_complete_workflow.call(cart: paid_cart)

    expect(published('bank_transfer.instructions_ready')).to be_empty
  end
end
