require 'spec_helper'

RSpec.describe AypexBankTransfer::ExpireSessionsJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, expires_at: 1.hour.ago)
  end

  context 'when the reconciler is healthy' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(true) }

    it 'expires the session and cancels the order' do
      described_class.perform_now

      expect(session.reload.status).to eq('expired')
      expect(order.reload.state).to eq('canceled')
    end

    it 'leaves sessions that have not yet expired alone' do
      session.update!(expires_at: 1.day.from_now)

      described_class.perform_now

      expect(session.reload.status).to eq('pending')
      expect(order.reload.state).not_to eq('canceled')
    end
  end

  # C2. The customer abandoned the bank transfer and paid by card. The
  # session is still pending and now past expiry, and order.allow_cancel? is
  # true for a paid, unshipped order -- so without the guard this job
  # cancels and restocks an order that has been paid in full.
  context 'when the order has already been paid another way' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(true) }

    # Totals pinned so a single card payment lands the order exactly on
    # 'paid' -- the default factory totals leave it in credit_owed, which
    # would prove a different thing.
    let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00, shipment_cost: 0) }

    before do
      create(:payment, order: order, amount: order.total, state: 'completed')
      order.update_with_updater!
      expect(order.reload.payment_state).to eq('paid')
    end

    it 'does not cancel the paid order' do
      described_class.perform_now

      order.reload
      expect(order.state).not_to eq('canceled')
      expect(order.payment_state).to eq('paid')
    end

    it 'closes the superseded session as canceled rather than expiring it' do
      described_class.perform_now

      expect(session.reload.status).to eq('canceled')
    end

    it 'does not publish the customer-facing expiry event' do
      allow(Spree::Events).to receive(:publish).and_call_original

      described_class.perform_now

      expect(Spree::Events).not_to have_received(:publish).with('bank_transfer.expired', anything)
      expect(Spree::Events).to have_received(:publish).with('bank_transfer.session_superseded', anything)
    end
  end

  context 'when the reconciler is unhealthy' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(false) }

    # THE critical test. A blind reconciler must never cancel: the customer
    # may well have paid and we simply cannot see it.
    it 'cancels nothing' do
      described_class.perform_now

      expect(session.reload.status).to eq('pending')
      expect(order.reload.state).not_to eq('canceled')
    end

    it 'publishes an unhealthy event instead' do
      expect(Spree::Events).to receive(:publish).with(
        'bank_transfer.reconciler_unhealthy',
        hash_including(payment_method_id: payment_method.id)
      )

      described_class.perform_now
    end
  end

  context 'when the order is not cancellable' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(true) }

    # order.allow_cancel? is false for an incomplete order. This must not
    # raise StateMachines::InvalidTransition - it must simply leave the
    # order alone while still expiring the session.
    let(:order) { create(:order) }

    it 'expires the session without raising and leaves the order alone' do
      expect { described_class.perform_now }.not_to raise_error

      expect(session.reload.status).to eq('expired')
      expect(order.reload.state).not_to eq('canceled')
    end
  end

  context 'when one payment method raises' do
    let(:other_payment_method) { create(:bank_transfer_gateway) }
    let(:other_order) { create(:completed_order_with_totals) }
    let!(:other_session) do
      create(:bank_transfer_payment_session,
             order: other_order, payment_method: other_payment_method, expires_at: 1.hour.ago)
    end

    before do
      failing_id = payment_method.id
      allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?) do |instance|
        if instance.id == failing_id
          raise ArgumentError, 'unknown reconciler'
        else
          true
        end
      end
    end

    it 'publishes an alert for the failing payment method and still processes the healthy one' do
      allow(Spree::Events).to receive(:publish).and_call_original

      expect { described_class.perform_now }.not_to raise_error

      expect(Spree::Events).to have_received(:publish).with(
        'bank_transfer.expiry_failed',
        hash_including(payment_method_id: payment_method.id)
      )
      expect(other_session.reload.status).to eq('expired')
      expect(other_order.reload.state).to eq('canceled')
    end
  end
end
