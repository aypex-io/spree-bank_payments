require 'spec_helper'

RSpec.describe AypexBankTransfer::ApplyDiscount do
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
end
