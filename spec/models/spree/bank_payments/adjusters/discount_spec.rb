require 'spec_helper'

RSpec.describe Spree::BankPayments::Adjusters::Discount do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory

  def cart_in(currency, price:)
    store = gateway.store
    store.update!(supported_currencies: [store.default_currency, currency].uniq.join(','))
    create(:bank_payments_bank_account, payment_method: gateway, currency: currency, offered: true)
    create(:cart_with_line_items, currency: currency, line_items_price: price)
  end

  it 'writes one manual discount per line item while bank transfer is selected' do
    cart = cart_in('USD', price: 100)
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart).map(&:kind)).to eq(%w[manual])
  end

  it 'takes 3% off the item total' do
    cart = cart_in('USD', price: 100)
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart).sum(:amount)).to eq(BigDecimal('-3.00'))
  end

  it 'labels the discount with its percentage' do
    cart = cart_in('USD', price: 100)
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart).first.label).to eq('Bank Transfer discount (3%)')
  end

  it 'removes its rows when bank transfer is released' do
    cart = cart_in('USD', price: 100)
    gateway.create_payment_session(order: cart)

    Spree::BankPayments::ReleaseSelection.call(purchase: cart)

    expect(bank_transfer_discounts(cart)).to be_empty
  end

  it 'keeps one set of rows when the buyer re-selects bank transfer' do
    cart = cart_in('USD', price: 100)
    2.times { gateway.create_payment_session(order: cart) }

    expect(bank_transfer_discounts(cart).count).to eq(1)
  end

  it 'weights the split by price times quantity' do
    cart = cart_in('USD', price: 10)
    create(:line_item, cart: cart, order: nil, price: 10, quantity: 3)
    cart.line_items.reload
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart).map(&:amount)).to contain_exactly(BigDecimal('-0.30'), BigDecimal('-0.90'))
  end

  # Spree refuses an amount with more decimals than its currency has.
  it 'rounds to whole yen' do
    cart = cart_in('JPY', price: 999)
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart).sum(:amount)).to eq(BigDecimal('-30'))
  end

  it 'writes nothing when the discount is zero' do
    gateway.update!(preferred_discount_percent: 0)
    cart = cart_in('USD', price: 100)
    gateway.create_payment_session(order: cart)

    expect(bank_transfer_discounts(cart)).to be_empty
  end

  # to_prepare calls the registration on every code reload.
  it 'registers the adjuster exactly once across reloads' do
    3.times { Spree::BankPayments.register_discount_adjuster! }

    expect(Spree.adjusters.map(&:name).count('Spree::BankPayments::Adjusters::Discount')).to eq(1)
  end
end
