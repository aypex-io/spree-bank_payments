require 'spec_helper'

RSpec.describe Spree::BankPayments::DetailSet do
  it 'exposes label, schemes and beneficiary' do
    set = described_class.new(
      'label' => 'UK payments', 'schemes' => %w[faster bacs],
      'beneficiary_name' => 'Example Store Ltd'
    )

    expect(set.label).to eq('UK payments')
    expect(set.schemes).to eq(%w[faster bacs])
    expect(set.beneficiary_name).to eq('Example Store Ltd')
  end

  it 'returns fields as ordered label/value pairs' do
    set = described_class.new('fields' => [
      { 'label' => 'Sort code', 'value' => '04-00-75' },
      { 'label' => 'Account number', 'value' => '12345678' }
    ])

    expect(set.fields).to eq([['Sort code', '04-00-75'], ['Account number', '12345678']])
  end

  # The whole point of label/value pairs: a market we have never heard of
  # renders without a migration or a view change.
  it 'renders coordinate labels it has never seen' do
    set = described_class.new('fields' => [{ 'label' => 'Elixir number', 'value' => '1234' }])

    expect(set.fields).to eq([['Elixir number', '1234']])
    expect(set).to be_usable
  end

  it 'drops blank-valued fields' do
    set = described_class.new('fields' => [
      { 'label' => 'IBAN', 'value' => 'GB00' },
      { 'label' => 'BIC', 'value' => '' }
    ])

    expect(set.fields).to eq([['IBAN', 'GB00']])
  end

  it 'is unusable with no fields at all' do
    expect(described_class.new('label' => 'Empty')).not_to be_usable
  end

  it 'tolerates symbol keys' do
    set = described_class.new(label: 'UK', fields: [{ label: 'Sort code', value: '04-00-75' }])

    expect(set.label).to eq('UK')
    expect(set.fields).to eq([['Sort code', '04-00-75']])
  end
end
