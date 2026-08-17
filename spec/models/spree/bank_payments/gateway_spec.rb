require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway do
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

  it 'rejects a reconciler that is not in the registry' do
    gateway.preferred_reconciler = 'no_such_provider'

    expect(gateway).not_to be_valid
    expect(gateway.errors[:preferred_reconciler]).to be_present
  end

  # An admin whose provider gem has been uninstalled still has to be able to
  # save this record -- deactivating it, or switching it back to 'manual', is
  # the recovery.
  it 'still saves a persisted gateway whose unregistered reconciler is unchanged' do
    gateway.preferred_reconciler = 'a_provider_gem_that_was_uninstalled'
    gateway.save!(validate: false)
    gateway.reload

    gateway.active = false

    expect(gateway).to be_valid
  end

  it 'lazily creates its reconciler state' do
    expect { gateway.reconciler_state }.to change(Spree::BankPayments::ReconcilerState, :count).by(1)
  end

  it 'exposes the offered account details for the store currency via the deprecated shim' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: Spree::Config[:currency], offered: true)

    detail_sets = gateway.bank_details

    expect(detail_sets.map(&:label)).to eq(['UK payments', 'International'])
    expect(detail_sets.first.beneficiary_name).to eq('Example Store Ltd')
    expect(detail_sets.first.fields).to eq(
      [['Sort code', '04-00-75'], ['Account number', '12345678']]
    )
    expect(detail_sets.last.fields).to eq(
      [['IBAN', 'GB00REVO00000000000000'], ['BIC', 'REVOGB21']]
    )
  end

  # Spree::PaymentMethod#method_type defaults to `type.demodulize.downcase`
  # ("gateway" for any Gateway subclass), and spree_storefront renders
  # "spree/checkout/payment/#{method_type}" during checkout -- NOT
  # description_partial_name or configuration_guide_partial_name, which are
  # separate lookups used only by the admin payment-method screens. Without
  # this override the checkout partial is unreachable in a real store even
  # though a view spec rendering it by explicit path stays green, so this
  # asserts the actual linkage: the value method_type returns really is the
  # directory our partial lives in.
  it 'overrides method_type so spree_storefront finds the checkout partial' do
    expect(gateway.method_type).to eq('spree_bank_payments')

    partial_path = Spree::BankPayments::Engine.root.join(
      'app', 'views', 'spree', 'checkout', 'payment',
      "_#{gateway.method_type}.html.erb"
    )

    expect(File.exist?(partial_path)).to be(true)
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
      create(:bank_payments_bank_account, payment_method: gateway, currency: order.currency, offered: true)

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
