require 'spec_helper'

RSpec.describe SpreeBankPayments::ApplyTransfer do
  # discount_percent: 0 -- the factory default is 3%, which (as of Task 9)
  # is genuinely applied on payment creation and would shift order.total
  # below the pinned 25.00 amount, making payment_state unreachably 'paid'.
  # This spec is about applying a transfer, not discount amount, so the
  # discount is switched off here rather than reworking the pinned totals.
  let(:payment_method) { create(:bank_transfer_gateway, preferred_discount_percent: 0) }
  # See ingest_transfer_spec.rb: :completed_order_with_totals is the
  # representative fixture (the order is checkout-complete before the
  # customer sees transfer instructions), pinned so order.total == the
  # 25.00 amount below, otherwise payment_state can never reach 'paid'.
  let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00, shipment_cost: 0) }
  let(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'TKF-7Q4X2', amount: 25.00, currency: 'GBP')
  end
  let(:transfer) do
    create(:bank_transfer_incoming_transfer,
           amount: 25.00, currency: 'GBP', reference_raw: 'TKF-7Q4X2',
           provider_transaction_id: 'TX-APPLY-1')
  end

  def apply(applied_by: nil)
    described_class.call(transfer: transfer, payment_session: session, applied_by: applied_by)
  end

  it 'completes the session and the payment' do
    apply

    expect(session.reload.status).to eq('completed')
    expect(order.reload.payment_state).to eq('paid')
    expect(transfer.reload).to be_applied
    expect(transfer.payment_session).to eq(session)
    # Auto path: transfer.amount == session.amount by construction (exact
    # match is a precondition of auto-apply), so the payment is credited
    # for the full session amount either way -- this pins that down
    # explicitly so a future change to the amount-crediting logic below
    # can't silently regress the automatic path.
    expect(order.payments.last.amount).to eq(25.00)
  end

  describe 'crediting the payment (Fix 6)' do
    # A larger, distinct order total so a 25.00 payment against it leaves a
    # real, non-zero balance -- proving payment_state reflects what the
    # payment actually recorded, not just "did it move at all".
    let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 250.00, shipment_cost: 0) }
    let(:session) do
      create(:bank_transfer_payment_session,
             order: order, payment_method: payment_method,
             external_id: 'TKF-7Q4X2', amount: 250.00, currency: 'GBP')
    end

    it "credits the payment with the transfer's amount, not the session's, when they differ" do
      admin = create(:admin_user)

      apply(applied_by: admin)

      payment = order.payments.last
      expect(payment.amount).to eq(25.00)
      expect(payment).to be_completed
      # 25.00 paid against a 250.00 order is a real shortfall, not 'paid'.
      expect(order.reload.payment_state).to eq('balance_due')
    end
  end

  describe 'applied_by tracking' do
    it 'sets applied_by_id and applied_at when given an admin user' do
      admin = create(:admin_user)

      apply(applied_by: admin)

      transfer.reload
      expect(transfer.applied_by_id).to eq(admin.id)
      expect(transfer.applied_at).to be_present
    end

    it 'leaves applied_by_id and applied_at nil when not given an admin user' do
      apply

      transfer.reload
      expect(transfer.applied_by_id).to be_nil
      expect(transfer.applied_at).to be_nil
    end
  end

  describe 'idempotency' do
    it 'is a no-op when called again on an already-applied transfer' do
      apply
      payment = order.payments.last

      expect { apply }.not_to change(Spree::Payment, :count)
      expect(order.payments.last).to eq(payment)
      expect(session.reload.status).to eq('completed')
      expect(transfer.reload).to be_applied
    end
  end
end
