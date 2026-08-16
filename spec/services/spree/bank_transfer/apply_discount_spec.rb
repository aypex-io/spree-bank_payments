require 'spec_helper'

RSpec.describe Spree::BankTransfer::ApplyDiscount do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:card_method) { create(:credit_card_payment_method) }
  # order_with_line_items has no `item_total` transient -- item_total is a
  # real DB column recalculated by update_with_updater! in the factory's
  # after(:create), so passing it directly is silently clobbered back to the
  # line_items_price default (10.00). Set item_total via the real transient
  # (line_items_price, 1 line item) so it is genuinely 100.00.
  let(:order) { create(:order_with_line_items, line_items_price: 100.00) }

  it 'discounts a percentage of item_total, not order total' do
    described_class.call(order: order, payment_method: payment_method)

    adjustment = order.adjustments.reload.find_by(source: payment_method)
    expect(adjustment.amount).to eq(-3.00)
  end

  it 'removes the discount when the customer switches to another method' do
    described_class.call(order: order, payment_method: payment_method)
    described_class.call(order: order, payment_method: card_method)

    expect(order.adjustments.reload.where(source: payment_method)).to be_empty
  end

  it 'creates no adjustment when the discount is zero' do
    payment_method.update!(preferred_discount_percent: 0)

    described_class.call(order: order, payment_method: payment_method)

    expect(order.adjustments.reload.where(source: payment_method)).to be_empty
  end

  it 'does not stack when applied twice' do
    2.times { described_class.call(order: order, payment_method: payment_method) }

    expect(order.adjustments.reload.where(source: payment_method).count).to eq(1)
  end

  it 'rounds a half-cent result correctly' do
    # 2.5% of 33.33 = 0.83325 -> rounds to 0.83.
    percent_order = create(:order_with_line_items, line_items_price: 33.33, shipment_cost: 0)
    fractional_method = create(:bank_transfer_gateway, preferred_discount_percent: 2.5)

    described_class.call(order: percent_order, payment_method: fractional_method)

    adjustment = percent_order.adjustments.reload.find_by(source: fractional_method)
    expect(adjustment.amount).to eq(-0.83)
  end

  it 'renders a fractional discount percent without truncation and without a trailing .0 on whole numbers' do
    fractional_order = create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0)
    fractional_method = create(:bank_transfer_gateway, preferred_discount_percent: 2.5)

    described_class.call(order: fractional_order, payment_method: fractional_method)
    fractional_adjustment = fractional_order.adjustments.reload.find_by(source: fractional_method)
    expect(fractional_adjustment.label).to eq('Bank Transfer discount (2.5%)')

    whole_order = create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0)
    described_class.call(order: whole_order, payment_method: payment_method)
    whole_adjustment = whole_order.adjustments.reload.find_by(source: payment_method)
    expect(whole_adjustment.label).to eq('Bank Transfer discount (3%)')
  end

  # Regression: PaymentDecorator fires ApplyDiscount for EVERY payment, not
  # just bank-transfer ones. Once a bank-transfer payment has actually
  # completed (money has arrived), a later payment on a different method --
  # store credit, an admin-added card payment, a refund correction, etc. --
  # must not strip the discount. Doing so raises order.total above what was
  # actually collected and flips an already-paid order back to balance_due.
  it 'keeps the discount and stays paid once a bank-transfer payment has completed, even when a later payment is created on another method' do
    # payment_state only updates once the order is checkout-complete (see
    # Spree::OrderUpdater#update), so :order_with_line_items (still in
    # checkout) can never reach 'paid'.
    discounted_order = create(:completed_order_with_totals, currency: 'GBP', line_items_price: 100.00, shipment_cost: 0)

    create(:payment, order: discounted_order, payment_method: payment_method, amount: 97.00, state: 'completed')
    discounted_order.reload
    expect(discounted_order.payment_state).to eq('paid')

    create(:payment, order: discounted_order, payment_method: card_method, amount: 0, state: 'checkout')
    discounted_order.reload

    expect(discounted_order.adjustments.where(source: payment_method)).not_to be_empty
    expect(discounted_order.total).to eq(97.00)
    expect(discounted_order.payment_state).to eq('paid')
  end
end
