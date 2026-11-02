require 'spec_helper'

RSpec.describe Spree::BankPayments::RecordManualTransfer do
  let(:gateway) { create(:bank_transfer_gateway) }
  let(:typed) do
    { payment_method: gateway, amount: '25.00', currency: 'gbp', reference: ' acme-7q4x2 ',
      payer_name: 'Jane Doe', occurred_at: '2026-11-02', recorded_by: nil }
  end

  def record(overrides = {})
    described_class.call(**typed.merge(overrides))
  end

  # The identity is derived from what was typed, so a resubmitted form is
  # recognised: the normalized reference, the payer name ignoring case.
  it 'recognises the same transfer typed differently' do
    record
    _, already_recorded = record(reference: 'ACME7Q4X2', payer_name: 'JANE DOE', currency: 'GBP')

    expect([already_recorded, Spree::BankPayments::IncomingTransfer.count]).to eq([true, 1])
  end

  it 'records it as a manual transfer' do
    transfer, = record

    expect(transfer.provider).to eq('manual')
  end

  it 'records the currency in capitals' do
    transfer, = record

    expect(transfer.currency).to eq('GBP')
  end

  it 'refuses a date it cannot read' do
    expect { record(occurred_at: 'yesterday-ish') }.to raise_error(ActiveModel::ValidationError)
  end

  it 'refuses an amount that is not a number' do
    expect { record(amount: 'lots') }.to raise_error(ActiveModel::ValidationError)
  end
end
