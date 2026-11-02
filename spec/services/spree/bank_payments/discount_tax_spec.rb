require 'spec_helper'

# A store may subclass the gateway (extra preferences, a bespoke reconciler).
# The discount must apply to it as well, so the adjuster matches subclasses.
class SubclassedBankTransferGateway < Spree::BankPayments::Gateway; end

# The discount is written as one manual Discount row per line item, which
# Spree 6 sums into the line's taxable basis: on a tax-inclusive market it
# reduces the VAT recorded, not just the total.
RSpec.describe 'bank transfer discount and tax' do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:tax_category) { create(:tax_category) }

  # One £100 line (in USD here; the currency is immaterial) under 20% VAT
  # included in the price.
  def vat_cart(payment_method: gateway, price: 100)
    cart = bank_transfer_cart(gateway: payment_method, price: price)
    cart.store.default_market.update!(tax_inclusive: true)
    create(:tax_rate, country_code: cart.tax_address.country.iso, tax_category: tax_category, amount: 0.20)
    cart.line_items.each { |line_item| line_item.update_columns(tax_category_id: tax_category.id) }
    # Reloaded first: the cart caches its market, still not tax-inclusive.
    cart.reload.recalculate_totals!
    cart.reload
  end

  it 'records included tax on the full price without bank transfer' do
    expect(vat_cart.included_tax_total).to eq(BigDecimal('16.67'))
  end

  it 'charges the discounted total with bank transfer' do
    cart = vat_cart
    gateway.create_payment_session(order: cart)

    expect(cart.reload.total).to eq(BigDecimal('97.00'))
  end

  # 97.00 - 97.00 / 1.2 = 16.17
  it 'records included tax on the discounted price with bank transfer' do
    cart = vat_cart
    gateway.create_payment_session(order: cart)

    expect(cart.reload.included_tax_total).to eq(BigDecimal('16.17'))
  end

  it 'counts a subclassed gateway' do
    subclassed = create(:bank_transfer_gateway, type: 'SubclassedBankTransferGateway').becomes(SubclassedBankTransferGateway)
    cart = vat_cart(payment_method: subclassed)
    subclassed.create_payment_session(order: cart)

    expect(cart.reload.included_tax_total).to eq(BigDecimal('16.17'))
  end

  # A payment-method concession, not a competing promotion: 20% + 3% = 23%.
  it 'stacks with a 20% promotion' do
    cart = bank_transfer_cart(gateway: gateway, price: 100)
    promotion = create(:promotion, kind: :automatic, code: nil, store: cart.store)
    Spree::Promotion::Actions::CreateItemAdjustments.create!(
      promotion: promotion,
      calculator: Spree::Calculator::PercentOnLineItem.new(preferred_percent: 20)
    )
    # Spree's promotion adjuster considers the promotions attached to a cart.
    cart.promotions << promotion
    cart.recalculate_totals!
    gateway.create_payment_session(order: cart)

    expect(cart.reload.total).to eq(BigDecimal('77.00'))
  end

  it 'is copied onto the placed order' do
    order, = place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway)

    expect(bank_transfer_discounts(order).sum(:amount)).to eq(BigDecimal('-3.00'))
  end

  it 'leaves the placed order owing the discounted total' do
    order, = place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway)

    expect(order.payments.last.amount).to eq(BigDecimal('97.00'))
  end
end
