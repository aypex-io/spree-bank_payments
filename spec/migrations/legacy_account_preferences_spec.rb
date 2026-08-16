require 'spec_helper'

RSpec.describe 'legacy account preference migration' do
  let(:gateway) do
    create(:bank_transfer_gateway).tap do |g|
      g.preferred_account_name = 'Old Ltd'
      g.preferred_account_iban = 'GB00OLD00000000000000'
      g.preferred_account_bic = 'OLDBGB21'
      g.save!
    end
  end

  it 'folds the flat preferences into one offered default-currency account' do
    gateway
    Spree::BankPayments::MigrateLegacyAccounts.call

    account = gateway.reload.bank_accounts.sole

    expect(account.currency).to eq(Spree::Config[:currency].upcase)
    expect(account).to be_offered
    expect(account.detail_sets.first.fields).to include(['IBAN', 'GB00OLD00000000000000'])
  end

  it 'is idempotent' do
    gateway
    2.times { Spree::BankPayments::MigrateLegacyAccounts.call }

    expect(gateway.reload.bank_accounts.count).to eq(1)
  end

  it 'leaves a gateway that already has accounts alone' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR', offered: true)

    expect { Spree::BankPayments::MigrateLegacyAccounts.call }.
      not_to change { gateway.reload.bank_accounts.count }
  end

  it 'creates nothing for a gateway with no legacy preferences set' do
    bare = create(:bank_transfer_gateway)
    bare.preferences = bare.preferences.merge(
      account_name: nil, account_iban: nil, account_bic: nil,
      account_sort_code: nil, account_number: nil
    )
    bare.save!

    Spree::BankPayments::MigrateLegacyAccounts.call

    expect(bare.reload.bank_accounts).to be_empty
  end
end
