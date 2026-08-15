require 'spec_helper'

RSpec.describe AypexBankTransfer::Gateway do
  let(:gateway) { create(:bank_transfer_gateway) }

  it 'does not require a payment source' do
    expect(gateway.source_required?).to be(false)
    expect(gateway.payment_source_class).to be_nil
  end

  it 'defaults to a three day expiry window' do
    expect(gateway.preferred_expiry_days).to eq(3)
  end

  it 'rejects a discount percent outside 0..100' do
    gateway.preferred_discount_percent = 150
    expect(gateway).not_to be_valid
  end

  it 'lazily creates its reconciler state' do
    expect { gateway.reconciler_state }.to change(AypexBankTransfer::ReconcilerState, :count).by(1)
  end

  it 'exposes bank details for display' do
    expect(gateway.bank_details).to include(account_name: 'Aypex Ltd', iban: 'GB00TEST00000000000000')
  end
end
