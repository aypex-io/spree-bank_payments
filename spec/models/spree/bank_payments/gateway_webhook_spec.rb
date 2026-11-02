require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway, '#parse_webhook_event' do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let!(:bank_account) do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
  end
  let(:order) { create(:completed_order_with_totals, currency: 'GBP') }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'ACME-7Q4X2', amount: 25.00, currency: 'GBP')
  end

  def stub_reconciler(transfer_data)
    reconciler = payment_method.reconciler
    allow(reconciler).to receive(:parse_webhook).and_return(transfer_data)
    allow(payment_method).to receive(:reconciler).and_return(reconciler)
  end

  let(:data) do
    Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-1', amount: 25.00,
      currency: 'GBP', reference: 'ACME-7Q4X2', payer_name: 'Jane Doe',
      occurred_at: Time.current, raw: {}
    )
  end

  it 'returns nil when the reconciler ignores the event' do
    stub_reconciler(nil)

    result = nil
    expect { result = payment_method.parse_webhook_event('{}', {}) }.
      not_to change(Spree::BankPayments::IncomingTransfer, :count)
    expect(result).to be_nil
  end

  # The gem applies the transfer itself, under its own matching rules, so
  # Spree's webhook workflow is given nothing to settle: it would otherwise
  # complete a cart whose session matched, placing an order nobody placed.
  it 'ingests the transfer and leaves nothing for Spree to settle' do
    stub_reconciler(data)

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
  end

  it 'applies the transfer it ingested' do
    stub_reconciler(data)

    payment_method.parse_webhook_event('{}', {})

    expect(Spree::BankPayments::IncomingTransfer.last).to be_applied
  end

  it 'persists the transfer but returns nil when nothing matches' do
    stub_reconciler(data.with(reference: 'ACME-NOPE1'))

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
    expect(Spree::BankPayments::IncomingTransfer.last).to be_unmatched
  end
end
