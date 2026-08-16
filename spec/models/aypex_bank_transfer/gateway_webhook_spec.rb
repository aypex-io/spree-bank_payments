require 'spec_helper'

RSpec.describe AypexBankTransfer::Gateway, '#parse_webhook_event' do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:order_with_line_items, currency: 'GBP') }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'TKF-7Q4X2', amount: 25.00, currency: 'GBP')
  end

  def stub_reconciler(transfer_data)
    reconciler = payment_method.reconciler
    allow(reconciler).to receive(:parse_webhook).and_return(transfer_data)
    allow(payment_method).to receive(:reconciler).and_return(reconciler)
  end

  let(:data) do
    AypexBankTransfer::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-1', amount: 25.00,
      currency: 'GBP', reference: 'TKF-7Q4X2', payer_name: 'Jane Doe',
      occurred_at: Time.current, raw: {}
    )
  end

  it 'returns nil when the reconciler ignores the event' do
    stub_reconciler(nil)

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
  end

  it 'ingests and reports a captured action on an exact match' do
    stub_reconciler(data)

    result = payment_method.parse_webhook_event('{}', {})

    expect(result[:action]).to eq(:captured)
    expect(result[:payment_session]).to eq(session)
    expect(AypexBankTransfer::IncomingTransfer.last).to be_applied
  end

  it 'persists the transfer but returns nil when nothing matches' do
    stub_reconciler(data.with(reference: 'TKF-NOPE1'))

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
    expect(AypexBankTransfer::IncomingTransfer.last).to be_unmatched
  end
end
