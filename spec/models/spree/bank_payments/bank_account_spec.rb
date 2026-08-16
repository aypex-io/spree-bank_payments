require 'spec_helper'

RSpec.describe Spree::BankPayments::BankAccount do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it 'upcases the currency on write' do
    account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'gbp')

    expect(account.reload.currency).to eq('GBP')
  end

  it 'requires at least one detail set with a non-blank field' do
    account = build(:bank_payments_bank_account, payment_method: payment_method, details: [])

    expect(account).not_to be_valid
    expect(account.errors[:details]).to be_present
  end

  it 'rejects a detail set whose fields are all blank' do
    account = build(:bank_payments_bank_account, payment_method: payment_method,
                    details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'Sort code', 'value' => '' }] }])

    expect(account).not_to be_valid
  end

  # The database, not a form validation, is what guarantees "one offered per
  # currency" -- the admin checklist and sync both depend on it being true.
  it 'refuses a second offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows a second NON-offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: false)

    expect(second).to be_valid
    expect { second.save! }.not_to raise_error
  end

  it 'refuses a duplicate provider_account_id on the same payment method' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')
    dup = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')

    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows many hand-created accounts with no provider_account_id' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'GBP')
    other = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'EUR')

    expect { other.save! }.not_to raise_error
  end
end
