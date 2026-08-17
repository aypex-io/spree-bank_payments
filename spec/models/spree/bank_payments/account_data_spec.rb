require 'spec_helper'

RSpec.describe Spree::BankPayments::AccountData do
  it 'carries provider id, currency and details' do
    data = described_class.new(provider_account_id: 'acc-1', currency: 'GBP', details: [])

    expect(data.provider_account_id).to eq('acc-1')
    expect(data.currency).to eq('GBP')
    expect(data.details).to eq([])
  end

  it 'defaults details to an empty array' do
    expect(described_class.new(provider_account_id: 'acc-1', currency: 'GBP').details).to eq([])
  end

  it 'round-trips through #with, preserving the other members' do
    data = described_class.new(provider_account_id: 'acc-1', currency: 'GBP')

    updated = data.with(currency: 'EUR')

    expect(updated.currency).to eq('EUR')
    expect(updated.provider_account_id).to eq(data.provider_account_id)
    expect(updated.details).to eq(data.details)
    expect(updated).not_to eq(data)
    expect(updated).to be_a(described_class)
  end

  # Additive: every existing construction call omits it, and a provider that
  # has never heard of pooling must keep working unchanged.
  it 'defaults pooled to false when a provider does not report it' do
    data = described_class.new(provider_account_id: 'acc_1', currency: 'GBP', details: [{ 'label' => 'x' }])

    expect(data.pooled).to be(false)
  end

  it 'carries pooled when a provider does report it' do
    data = described_class.new(provider_account_id: 'acc_1', currency: 'GBP',
                               details: [{ 'label' => 'x' }], pooled: true)

    expect(data.pooled).to be(true)
  end
end
