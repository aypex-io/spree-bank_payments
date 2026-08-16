require 'spec_helper'

RSpec.describe SpreeBankTransfer::TransferData do
  let(:occurred_at) { Time.zone.now }

  it 'constructs with all members provided' do
    transfer = described_class.new(
      provider: 'manual',
      provider_transaction_id: 'txn_123',
      amount: 100,
      currency: 'USD',
      reference: 'ABC123',
      payer_name: 'Jane Doe',
      occurred_at: occurred_at,
      raw: { foo: 'bar' }
    )

    expect(transfer.provider).to eq('manual')
    expect(transfer.provider_transaction_id).to eq('txn_123')
    expect(transfer.amount).to eq(100)
    expect(transfer.currency).to eq('USD')
    expect(transfer.reference).to eq('ABC123')
    expect(transfer.payer_name).to eq('Jane Doe')
    expect(transfer.occurred_at).to eq(occurred_at)
    expect(transfer.raw).to eq({ foo: 'bar' })
  end

  it 'defaults payer_name and reference to nil when omitted' do
    transfer = described_class.new(
      provider: 'manual',
      provider_transaction_id: 'txn_123',
      amount: 100,
      currency: 'USD',
      occurred_at: occurred_at
    )

    expect(transfer.payer_name).to be_nil
    expect(transfer.reference).to be_nil
  end

  it 'defaults raw to an empty hash, not nil, when omitted' do
    transfer = described_class.new(
      provider: 'manual',
      provider_transaction_id: 'txn_123',
      amount: 100,
      currency: 'USD',
      occurred_at: occurred_at
    )

    expect(transfer.raw).to eq({})
    expect(transfer.raw).not_to be_nil
  end

  it 'round-trips through #with' do
    transfer = described_class.new(
      provider: 'manual',
      provider_transaction_id: 'txn_123',
      amount: 100,
      currency: 'USD',
      occurred_at: occurred_at
    )

    updated = transfer.with(amount: 200)

    expect(updated.amount).to eq(200)
    expect(updated.provider).to eq(transfer.provider)
    expect(updated.provider_transaction_id).to eq(transfer.provider_transaction_id)
    expect(updated.currency).to eq(transfer.currency)
    expect(updated.occurred_at).to eq(transfer.occurred_at)
    expect(updated).not_to eq(transfer)
    expect(updated).to be_a(described_class)
  end
end
