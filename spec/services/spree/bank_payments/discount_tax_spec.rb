require 'spec_helper'

# The discount is applied as one adjustment per line item (not a single
# order-level adjustment), so it reaches Spree::LineItem#taxable_adjustment_total
# and therefore actually reduces recorded tax on a tax-inclusive (VAT) store.
#
# Before this change these expectations were impossible: an order-level
# adjustment never reaches taxable_adjustment_total, so included_tax_total
# stayed pinned to the undiscounted price.
RSpec.describe 'bank-transfer discount and tax' do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:tax_category) { create(:tax_category) }

  # 20% VAT, included in price, on a zone that actually matches the order.
  def apply_inclusive_vat!(order, rate: 0.2)
    country = order.tax_address.country
    zone = create(:zone, name: "VAT-#{SecureRandom.hex(4)}", kind: 'country')
    Spree::ZoneMember.create!(zoneable: country, zone: zone)

    create(
      :tax_rate,
      zone: zone,
      tax_category: tax_category,
      amount: rate,
      included_in_price: true
    )

    order.line_items.each { |li| li.update_columns(tax_category_id: tax_category.id) }
    order.reload
    order.create_tax_charge!
    order.update_with_updater!
    order.reload
  end

  def order_with_vat(price: 100.00, quantity: 1)
    order = create(:order_with_line_items, line_items_price: price, shipment_cost: 0)
    order.line_items.first.update!(quantity: quantity) if quantity != 1
    apply_inclusive_vat!(order)
    order
  end

  # AdjustmentsUpdater runs the non-tax adjusters, persists their totals, then
  # runs Tax -- which recomputes from taxable_basis. Registered after Tax, our
  # contribution lands too late and tax is still computed on the undiscounted
  # price, so the position in this array is the whole fix.
  it 'registers the discount adjuster exactly once, before the tax adjuster' do
    names = Spree.adjusters.map(&:name)

    expect(names.count('Spree::BankPayments::Adjuster::Discount')).to eq(1)
    expect(names.index('Spree::BankPayments::Adjuster::Discount')).
      to be < names.index('Spree::Adjustable::Adjuster::Tax')
  end

  it 'stays registered exactly once when to_prepare fires again' do
    3.times { Spree::BankPayments.register_discount_adjuster! }

    names = Spree.adjusters.map(&:name)
    expect(names.count('Spree::BankPayments::Adjuster::Discount')).to eq(1)
    expect(names.index('Spree::BankPayments::Adjuster::Discount')).
      to be < names.index('Spree::Adjustable::Adjuster::Tax')
  end

  it 'reduces recorded included tax proportionally on a tax-inclusive store' do
    order = order_with_vat(price: 100.00)

    # Sanity: the fixture really is taxed inclusively before we touch it.
    expect(order.included_tax_total).to be > 0
    expect(order.included_tax_total).to eq(16.67) # 100 - 100/1.2
    expect(order.total).to eq(100.00)

    described_class = Spree::BankPayments::ApplyDiscount
    described_class.call(order: order, payment_method: payment_method)
    order.reload

    # 3% off 100.00 => taxable basis 97.00 => included VAT 97 - 97/1.2 = 16.17
    expect(order.total).to eq(97.00)
    expect(order.included_tax_total).to eq(16.17)
  end

  it 'stacks with a real Spree promotion instead of cancelling it' do
    order = create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0)
    create(:promotion, :with_line_item_adjustment, adjustment_rate: 20, code: 'TWENTY')
    order.coupon_code = 'TWENTY'
    Spree::PromotionHandler::Coupon.new(order).apply
    order.update_with_updater!
    order.reload

    expect(order.line_item_adjustments.promotion.eligible).not_to be_empty

    Spree::BankPayments::ApplyDiscount.call(order: order, payment_method: payment_method)
    order.reload

    promo_adjustments = order.all_adjustments.promotion
    discount_adjustments = order.all_adjustments.where(source: payment_method)

    expect(promo_adjustments.where(eligible: false)).to be_empty
    expect(discount_adjustments.where(eligible: false)).to be_empty
    expect(promo_adjustments.eligible.sum(:amount)).to eq(-20.00)
    # Base stays item_total, so the two stack: 20 + 3 = 23 off.
    expect(discount_adjustments.sum(:amount)).to eq(-3.00)
    expect(order.total).to eq(77.00)
  end

  it 'does not double-count when an order-level promotion is also present' do
    order = order_with_vat(price: 100.00)
    create(:promotion, :with_order_adjustment, weighted_order_adjustment_amount: 10, code: 'TENOFF')
    order.coupon_code = 'TENOFF'
    Spree::PromotionHandler::Coupon.new(order).apply
    order.update_with_updater!
    order.reload

    expect(order.order_level_promo_total).to eq(-10.00)

    Spree::BankPayments::ApplyDiscount.call(order: order, payment_method: payment_method)
    order.reload

    # taxable_basis = taxable_amount (97.00, already includes our discount)
    # plus the proportional share of the order-level promo (-10.00) => 87.00.
    line_item = order.line_items.first
    expect(line_item.taxable_amount).to eq(97.00)
    expect(line_item.taxable_basis).to eq(87.00)

    expect(order.total).to eq(87.00)
    expect(order.included_tax_total).to eq(14.50) # 87 - 87/1.2
  end
end
