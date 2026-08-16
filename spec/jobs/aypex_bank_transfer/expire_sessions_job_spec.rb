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
end
