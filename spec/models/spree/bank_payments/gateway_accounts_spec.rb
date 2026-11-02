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

  it 'is unavailable for a cart whose currency has no offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    cart = create(:cart, currency: 'EUR')

    expect(gateway.available_for_order?(cart)).to be(false)
  end

  it 'is available when the cart currency has an offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    cart = create(:cart, currency: 'GBP')

    expect(gateway.available_for_order?(cart)).to be(true)
  end

  # Settlement must survive the merchant retiring the only account in the
  # cart's currency after the cart already quoted this gateway.
  it 'is available for a cart that already holds a same-currency session, even with no account offered' do
    account = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    cart = create(:cart_with_line_items, currency: 'GBP')
    create(:bank_transfer_payment_session, cart: cart, payment_method: gateway, currency: 'GBP')
    account.update!(offered: false)

    expect(gateway.available_for_order?(cart)).to be(true)
  end

  # Pins the currency scope: a cart quoted in GBP and then switched to a
  # currency with no offered account must not inherit availability from its
  # own stale GBP session -- an empty instructions block with nowhere to send
  # money is worse than not listing the method at all.
  it 'is unavailable once the same cart switches to a currency with no offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    cart = create(:cart_with_line_items, currency: 'GBP')
    create(:bank_transfer_payment_session, cart: cart, payment_method: gateway, currency: 'GBP')

    cart.update!(currency: 'USD')

    expect(gateway.available_for_order?(cart)).to be(false)
  end
end
