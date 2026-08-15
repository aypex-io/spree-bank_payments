require 'spec_helper'

RSpec.describe AypexBankTransfer::ApplyTransfer do
  let(:payment_method) { create(:bank_transfer_gateway) }
  # See ingest_transfer_spec.rb: pinned so order.total == the 25.00 amount
  # below, otherwise payment_state can never reach 'paid'.
  let(:order) { create(:order_with_line_items, currency: 'GBP', line_items_price: 25.00, shipment_cost: 0) }
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
