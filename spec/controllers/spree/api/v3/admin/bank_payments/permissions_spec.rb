require 'spec_helper'

RSpec.describe 'Spree::BankPayments Admin API foundation' do
  it 'registers a bank_payments permission scope' do
    expect(Spree.permissions.catalog_keys).to include('read_bank_payments', 'write_bank_payments')
  end

  it 'gives incoming transfers a btxfr_ prefixed id' do
    expect(create(:bank_transfer_incoming_transfer).prefixed_id).to start_with('btxfr_')
  end

  it 'gives bank accounts a bacct_ prefixed id' do
    expect(create(:bank_payments_bank_account).prefixed_id).to start_with('bacct_')
  end
end
