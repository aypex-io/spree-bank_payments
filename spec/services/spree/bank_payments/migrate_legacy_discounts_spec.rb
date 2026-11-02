require 'spec_helper'

# Spree's upgrade (spree:migrate_adjustments_to_typed_rows) does not know a
# 5.x bank transfer discount, an adjustment sourced from a payment method:
# it writes it as a 0.00 surcharge Fee tagged with the legacy source. The
# order's stored total still includes the discount, but the next time Spree
# re-sums it (a cancel, an edit, a refund) the total rises by the discount.
RSpec.describe Spree::BankPayments::MigrateLegacyDiscounts do
  let(:gateway) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals, line_items_price: 100) }
  let(:line_item) { order.line_items.first }
  let(:undiscounted_total) { order.total }
  let(:legacy) { Class.new(ActiveRecord::Base) { self.table_name = 'spree_adjustments' } }

  # What a 5.x order paid by bank transfer looks like once Spree's upgrade
  # has run over it.
  def upgrade_from_5x!(payment_method: gateway)
    undiscounted_total
    legacy.create!(order_id: order.id, adjustable_type: 'Spree::LineItem', adjustable_id: line_item.id,
                   source_type: 'Spree::PaymentMethod', source_id: payment_method.id,
                   amount: BigDecimal('-3.00'), label: 'Bank Transfer discount (3%)', eligible: true)
    Spree::Fee.create!(order: order, line_item: line_item, amount: 0, kind: 'surcharge',
                       label: 'Bank Transfer discount (3%)',
                       metadata: { 'legacy_source_type' => 'Spree::PaymentMethod', 'legacy_source_id' => payment_method.id })
    order.update_columns(total: undiscounted_total - 3, adjustment_total: -3)
  end

  def resum!
    Spree.order_recalculate_totals_workflow.call(order: order.reload)
    order.reload
  end

  it 'replaces the zero surcharge with the discount it was' do
    upgrade_from_5x!
    described_class.call

    expect(bank_transfer_discounts(order).sum(:amount)).to eq(BigDecimal('-3.00'))
  end

  it 'removes the surcharge' do
    upgrade_from_5x!
    described_class.call

    expect(Spree::Fee.where(order_id: order.id)).to be_empty
  end

  it 'keeps the order owing the discounted total when Spree re-sums it' do
    upgrade_from_5x!
    described_class.call

    expect(resum!.total).to eq(undiscounted_total - 3)
  end

  it 'is idempotent' do
    upgrade_from_5x!
    2.times { described_class.call }

    expect(bank_transfer_discounts(order).count).to eq(1)
  end

  it "leaves another payment method's surcharge alone" do
    other = create(:check_payment_method)
    upgrade_from_5x!(payment_method: other)
    described_class.call

    expect(Spree::Fee.where(order_id: order.id).count).to eq(1)
  end
end
