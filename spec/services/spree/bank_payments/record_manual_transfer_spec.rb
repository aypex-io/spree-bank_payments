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

  # The dashboard sends the day the money arrived, on the store's calendar.
  # Read in UTC, a transfer received today showed as "about 23 hours ago",
  # and in a store west of UTC it fell on the day before.
  it "reads a typed date as that day in the store's time zone" do
    transfer, = record(occurred_at: '2026-11-04', time_zone: 'America/New_York')

    expect(transfer.occurred_at).to eq(Time.find_zone('America/New_York').local(2026, 11, 4))
  end

  it 'reads a full timestamp as the instant it names' do
    transfer, = record(occurred_at: '2026-11-04T10:15:00Z', time_zone: 'America/New_York')

    expect(transfer.occurred_at).to eq(Time.utc(2026, 11, 4, 10, 15))
  end

  # The identity hashes the typed date, so reading it in another zone must
  # not make a transfer recorded before this change look new.
  it 'recognises a transfer recorded before dates were read in the store time zone' do
    record(occurred_at: '2026-11-04')
    _, already_recorded = record(occurred_at: '2026-11-04', time_zone: 'Pacific/Auckland')

    expect(already_recorded).to be(true)
  end

  # A timestamp's identity is its date where it was read before: Time.zone.
  it 'recognises a timestamped transfer recorded before dates were read in the store time zone' do
    record(occurred_at: '2026-11-05T02:00:00Z')
    _, already_recorded = record(occurred_at: '2026-11-05T02:00:00Z', time_zone: 'America/New_York')

    expect(already_recorded).to be(true)
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
