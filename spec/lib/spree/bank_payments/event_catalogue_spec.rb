require 'spec_helper'

RSpec.describe 'Spree::BankPayments event catalogue' do
  customer_facing = %w[
    bank_transfer.instructions_ready
    bank_transfer.reminder_due
    bank_transfer.expired
    bank_transfer.session_superseded
  ]

  operational = %w[
    bank_transfer.reconciler_unhealthy
    bank_transfer.expiry_failed
    bank_transfer.reconciler_health.unhealthy
    bank_transfer.reconciler_health.recovered
  ]

  (customer_facing + operational).each do |name|
    it "declares #{name}" do
      expect(Spree::Events.catalog.find(name)).not_to be_nil
    end
  end

  # Their payloads carry reconciler error text, which must never leave the
  # store through a webhook endpoint subscribed to `*`.
  operational.each do |name|
    it "keeps #{name} off webhooks" do
      expect(Spree::Events.catalog.webhook?(name)).to be(false)
    end
  end

  customer_facing.each do |name|
    it "offers #{name} to webhooks" do
      expect(Spree::Events.catalog.webhook?(name)).to be(true)
    end
  end

  describe Spree::PaymentSessions::BankTransfer do
    let(:gateway) { create(:bank_transfer_gateway) }
    let(:order) { create(:order, email: 'buyer@example.com', currency: 'GBP') }
    let(:session) do
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
      create(:bank_transfer_payment_session, order: order, payment_method: gateway, amount: 97.00, currency: 'GBP')
    end

    it 'gives a webhook receiver everything it needs to email the buyer' do
      expect(session.notification_payload.keys).
        to include('reference', 'amount', 'currency', 'expires_at', 'order_email', 'bank_details')
    end

    it 'uses string keys' do
      expect(session.notification_payload.keys).to all(be_a(String))
    end

    it 'identifies the session by its prefixed id' do
      expect(session.notification_payload['payment_session_id']).to eq(session.prefixed_id)
    end

    it 'quotes the bank details the session was quoted against' do
      labels = session.notification_payload['bank_details'].map { |set| set['label'] }

      expect(labels).to eq(['UK payments', 'International'])
    end

    # The webhook subscriber drops an event with no store, and the reminder
    # and expiry jobs run with no current store.
    it "publishes under the gateway's store when there is no current store" do
      published_store = nil
      allow(Spree::Events).to receive(:publish) { published_store = Spree::Current.store }
      Spree::Current.store = nil

      session.publish_bank_transfer_event('bank_transfer.reminder_due')

      expect(published_store).to eq(gateway.store)
    end
  end
end
