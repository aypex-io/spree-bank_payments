require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway, 'accounts' do
  let(:gateway) { create(:bank_transfer_gateway) }

  it 'returns the offered account for a currency' do
    gbp = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR', offered: true)

    expect(gateway.offered_account_for('GBP')).to eq(gbp)
  end

  it 'ignores non-offered and inactive accounts when quoting' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: false)

    expect(gateway.offered_account_for('GBP')).to be_nil
  end

  it 'returns every detail set for the quoted account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

    labels = gateway.bank_details_for('GBP').map(&:label)

    expect(labels).to eq(['UK payments', 'International'])
  end

  it 'is unavailable for an order whose currency has no offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    order = create(:order, currency: 'EUR')

    expect(gateway.available_for_order?(order)).to be(false)
  end

  it 'is available when the order currency has an offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    order = create(:order, currency: 'GBP')

    expect(gateway.available_for_order?(order)).to be(true)
  end

  # 5.2.0 is a minor: removing a public method would break a host's custom view
  # or another extension.
  it 'keeps #bank_details as a deprecated shim that actually warns' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: Spree::Config[:currency], offered: true)

    expect(Spree::Deprecation).to receive(:warn).with(/bank_details.*bank_details_for/)

    expect(gateway).to respond_to(:bank_details)
    expect(gateway.bank_details).to be_an(Array)
  end

  # The upgrade-day case: a host on 5.1.1 upgrades to 5.2.0 with no
  # BankAccount configured yet, and something -- a custom view, another
  # extension -- still calls the deprecated shim. It must degrade to "no
  # details to show", never raise.
  it 'returns an empty array from #bank_details when no account is offered' do
    expect(gateway.bank_details).to eq([])
  end
end
