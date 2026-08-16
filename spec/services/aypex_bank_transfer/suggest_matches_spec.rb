require 'spec_helper'

RSpec.describe AypexBankTransfer::SuggestMatches do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:transfer) do
    create(:bank_transfer_incoming_transfer,
           amount: 25.00, currency: 'GBP', reference_raw: 'GARBAGE', payer_name: 'Jane Doe',
           payment_method_id: payment_method.id)
  end

  it 'ranks an exact amount and currency match first' do
    match = create(:bank_transfer_payment_session,
                   payment_method: payment_method, amount: 25.00, currency: 'GBP')
    create(:bank_transfer_payment_session,
           payment_method: payment_method, amount: 99.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call.first).to eq(match)
  end

  it 'excludes sessions that are no longer open' do
    closed = create(:bank_transfer_payment_session,
                    payment_method: payment_method, amount: 25.00, currency: 'GBP')
    closed.complete!

    expect(described_class.new(transfer: transfer).call).not_to include(closed)
  end

  it 'returns at most five suggestions' do
    7.times { create(:bank_transfer_payment_session, payment_method: payment_method, amount: 25.00, currency: 'GBP') }

    expect(described_class.new(transfer: transfer).call.length).to eq(5)
  end

  it 'includes a fuzzy payer-name match even when the amount does not match' do
    order = create(:order, bill_address: create(:address, firstname: 'Jane', lastname: 'Doe'))
    match = create(:bank_transfer_payment_session,
                   payment_method: payment_method, order: order, amount: 999.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call).to include(match)
  end

  it 'degrades to amount matching when pg_trgm is unavailable' do
    allow(AypexBankTransfer).to receive(:pg_trgm_available?).and_return(false)
    match = create(:bank_transfer_payment_session,
                   payment_method: payment_method, amount: 25.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call).to include(match)
  end

  it 'never suggests a session belonging to another gateway/store' do
    other_payment_method = create(:bank_transfer_gateway)
    other_session = create(:bank_transfer_payment_session,
                           payment_method: other_payment_method, amount: 25.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call).not_to include(other_session)
  end

  it 'returns no suggestions when the transfer has no known payment method' do
    transfer.update_column(:payment_method_id, nil)
    create(:bank_transfer_payment_session, payment_method: payment_method, amount: 25.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call).to eq([])
  end
end
