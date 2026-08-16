require 'spec_helper'

RSpec.describe AypexBankTransfer::Gateway do
  let(:gateway) { create(:bank_transfer_gateway) }

  it 'does not require a payment source' do
    expect(gateway.source_required?).to be(false)
    expect(gateway.payment_source_class).to be_nil
  end

  it 'defaults to a three day expiry window' do
    expect(gateway.preferred_expiry_days).to eq(3)
  end

  it 'rejects a discount percent outside 0..100' do
    gateway.preferred_discount_percent = 150
    expect(gateway).not_to be_valid
  end

  it 'lazily creates its reconciler state' do
    expect { gateway.reconciler_state }.to change(AypexBankTransfer::ReconcilerState, :count).by(1)
  end

  it 'exposes bank details for display' do
    expect(gateway.bank_details).to include(account_name: 'Aypex Ltd', iban: 'GB00TEST00000000000000')
  end

  describe '#create_payment_session' do
    # item_total 100, discount 3% (factory default) -> discounted total 97.00.
    # order_with_line_items has no item_total transient (see
    # apply_discount_spec.rb): use the real line_items_price transient.
    let(:order) { create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0) }

    it 'quotes the discounted total, not the undiscounted one' do
      session = gateway.create_payment_session(order: order)

      expect(session.amount).to eq(order.reload.total)
      expect(session.amount).to eq(97.00)
    end

    it 'does not move the goalposts once a payment is later created (reconciliation-time hook is a no-op)' do
      session = gateway.create_payment_session(order: order)
      quoted_amount = session.amount

      create(:payment, order: order, payment_method: gateway, amount: quoted_amount)

      expect(order.reload.total).to eq(quoted_amount)
    end

    it 'publishes bank_transfer.instructions_ready for the persisted session, after creation' do
      published_payload = nil
      allow(Spree::Events).to receive(:publish) do |name, payload|
        published_payload = payload if name == 'bank_transfer.instructions_ready'
      end

      session = gateway.create_payment_session(order: order)

      # Proves the event fires after Spree::PaymentSessions::BankTransfer.create!
      # (not before, and not against some other record): the payload's id must
      # match the id of the session actually returned/persisted.
      expect(session.id).to be_present
      expect(published_payload).not_to be_nil
      expect(published_payload[:payment_session_id]).to eq(session.id)
    end
  end
end
