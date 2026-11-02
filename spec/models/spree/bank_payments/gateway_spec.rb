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

  # #health calls this twice, on every checkout render.
  it 'memoizes its reconciler state rather than re-querying per call' do
    state = gateway.reconciler_state

    expect(gateway.reconciler_state).to equal(state)
  end

  it 'drops the memoized reconciler state on reload' do
    state = gateway.reconciler_state

    expect(gateway.reload.reconciler_state).not_to equal(state)
  end

  # Two first-ever concurrent checkout renders both miss the SELECT and both
  # INSERT; the unique index on payment_method_id makes the loser raise. The
  # winner has committed a row by then, so the loser must read it, not 500.
  it 'recovers the row when a concurrent first-ever call wins the insert race' do
    existing = Spree::BankPayments::ReconcilerState.create!(payment_method_id: gateway.id)

    allow(Spree::BankPayments::ReconcilerState).
      to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))

    expect(gateway.reconciler_state).to eq(existing)
  end

  it 'reports its API type as bank_transfer' do
    expect(described_class.api_type).to eq('bank_transfer')
  end

  it 'requires a payment session' do
    expect(gateway.session_required?).to be(true)
  end

  # Spree holds dispatch of an order whose pending payments all defer
  # capture (Fulfillments::Fulfill#ensure_ready_to_hand_over). Capturing "at
  # checkout" keeps an unpaid bank transfer order out of that exemption.
  it 'captures at checkout so Spree holds dispatch until it is paid' do
    gateway.store.update!(preferred_capture_method: 'on_dispatch')

    expect(gateway.resolved_capture_method).to eq('checkout')
  end

  it 'refuses to purchase outside a payment session' do
    expect(gateway.purchase(Spree::Money.new(10, currency: 'GBP'), nil, {}).success?).to be(false)
  end

  it 'refuses to authorize outside a payment session' do
    expect(gateway.authorize(Spree::Money.new(10, currency: 'GBP'), nil, {}).success?).to be(false)
  end

  # Only ApplyTransfer captures, once the reconciler has seen the money.
  it 'confirms a capture without contacting anyone' do
    expect(gateway.capture(Spree::Money.new(10, currency: 'GBP'), 'ACME-7Q4X2', {}).success?).to be(true)
  end

  it 'offers staff no capture action' do
    expect(gateway.actions).to eq(%w[void])
  end

  it 'hides the legacy single-account preferences from the dashboard' do
    keys = described_class.preference_schema.map { |entry| entry[:key].to_s }

    expect(keys).not_to include('account_iban')
  end

  describe '#available_for_order?' do
    let(:cart) { create(:cart_with_line_items, currency: 'GBP') }

    it 'is available for a cart in a currency with an offered account' do
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

      expect(gateway.available_for_order?(cart)).to be(true)
    end

    it 'is unavailable for a cart in a currency with no offered account' do
      expect(gateway.available_for_order?(cart)).to be(false)
    end

    it 'stays available for a cart that already holds a session in its currency' do
      create(:bank_transfer_payment_session, cart: cart, payment_method: gateway, currency: 'GBP')

      expect(gateway.available_for_order?(cart)).to be(true)
    end
  end
end
