require 'spec_helper'

RSpec.describe Spree::BankPayments::ApplyDiscount do
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

    adjustment = order.all_adjustments.reload.find_by(source: payment_method)
    expect(adjustment.amount).to eq(-3.00)
  end

  it 'applies the discount as line-item adjustments, not an order-level one' do
    multi_order = create(:order_with_line_items, line_items_count: 2, line_items_price: 50.00, shipment_cost: 0)

    described_class.call(order: multi_order, payment_method: payment_method)

    adjustments = multi_order.all_adjustments.reload.where(source: payment_method)
    expect(adjustments.count).to eq(2)
    expect(adjustments.map(&:adjustable_type).uniq).to eq(['Spree::LineItem'])
    expect(adjustments.map(&:adjustable_id).sort).to eq(multi_order.line_items.map(&:id).sort)
    # Nothing left hanging on the order itself.
    expect(multi_order.adjustments.reload.where(source: payment_method)).to be_empty
    expect(adjustments.sum(:amount)).to eq(-3.00)
  end

  # Largest-remainder allocation, not naive per-line rounding. This is
  # load-bearing: order.total must match the amount quoted on the payment
  # session to the cent, or auto-apply (which requires exact amount equality)
  # sends every payment to the manual admin queue.
  it 'allocates across line items so the parts sum exactly to the intended total' do
    # 3 x 33.33 = 99.99; 2.5% = 2.49975 -> 2.50.
    # Naive per-line rounding gives 0.83 x 3 = 2.49 -- a cent short.
    awkward_order = create(:order_with_line_items, line_items_count: 3, line_items_price: 33.33, shipment_cost: 0)
    fractional_method = create(:bank_transfer_gateway, preferred_discount_percent: 2.5)

    described_class.call(order: awkward_order, payment_method: fractional_method)
    awkward_order.reload

    adjustments = awkward_order.all_adjustments.where(source: fractional_method)
    expect(adjustments.count).to eq(3)
    expect(adjustments.sum(:amount)).to eq(-2.50)
    expect(adjustments.map(&:amount).map(&:to_f).sort).to eq([-0.84, -0.83, -0.83])
    expect(awkward_order.item_total).to eq(99.99)
    expect(awkward_order.total).to eq(97.49)
  end

  it 'removes the discount when the customer switches to another method' do
    described_class.call(order: order, payment_method: payment_method)
    described_class.call(order: order, payment_method: card_method)

    expect(order.all_adjustments.reload.where(source: payment_method)).to be_empty
  end

  # Regression: remove_existing used to query only order.adjustments, which
  # would have orphaned every line-item adjustment on a payment-method switch
  # -- silently leaking margin.
  it 'removes line-item discount adjustments on a payment-method switch' do
    multi_order = create(:order_with_line_items, line_items_count: 3, line_items_price: 20.00, shipment_cost: 0)

    described_class.call(order: multi_order, payment_method: payment_method)
    expect(multi_order.all_adjustments.reload.where(source: payment_method).count).to eq(3)

    described_class.call(order: multi_order, payment_method: card_method)
    multi_order.reload

    expect(Spree::Adjustment.where(source: payment_method, order_id: multi_order.id)).to be_empty
    expect(multi_order.line_items.map(&:taxable_adjustment_total)).to all(eq(0))
    expect(multi_order.total).to eq(60.00)
  end

  it 'creates no adjustment when the discount is zero' do
    payment_method.update!(preferred_discount_percent: 0)

    described_class.call(order: order, payment_method: payment_method)

    expect(order.all_adjustments.reload.where(source: payment_method)).to be_empty
  end

  it 'does not stack when applied twice' do
    2.times { described_class.call(order: order, payment_method: payment_method) }

    expect(order.all_adjustments.reload.where(source: payment_method).count).to eq(1)
  end

  it 'rounds a half-cent result correctly' do
    # 2.5% of 33.33 = 0.83325 -> rounds to 0.83.
    percent_order = create(:order_with_line_items, line_items_price: 33.33, shipment_cost: 0)
    fractional_method = create(:bank_transfer_gateway, preferred_discount_percent: 2.5)

    described_class.call(order: percent_order, payment_method: fractional_method)

    adjustment = percent_order.all_adjustments.reload.find_by(source: fractional_method)
    expect(adjustment.amount).to eq(-0.83)
  end

  it 'renders a fractional discount percent without truncation and without a trailing .0 on whole numbers' do
    fractional_order = create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0)
    fractional_method = create(:bank_transfer_gateway, preferred_discount_percent: 2.5)

    described_class.call(order: fractional_order, payment_method: fractional_method)
    fractional_adjustment = fractional_order.all_adjustments.reload.find_by(source: fractional_method)
    expect(fractional_adjustment.label).to eq('Bank Transfer discount (2.5%)')

    whole_order = create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0)
    described_class.call(order: whole_order, payment_method: payment_method)
    whole_adjustment = whole_order.all_adjustments.reload.find_by(source: payment_method)
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

    expect(discounted_order.all_adjustments.where(source: payment_method)).not_to be_empty
    expect(discounted_order.total).to eq(97.00)
    expect(discounted_order.payment_state).to eq('paid')
  end
end
