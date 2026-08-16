require 'spec_helper'

RSpec.describe Spree::BankTransfer::Gateway do
  describe '#reconciler_healthy?' do
    context 'with the Manual reconciler' do
      let(:payment_method) { create(:bank_transfer_gateway, preferences: { reconciler: 'manual' }) }

      it 'is healthy regardless of reconciler state, including a nil last_successful_run_at' do
        payment_method.reconciler_state.update!(last_successful_run_at: nil)

        expect(payment_method.reconciler_healthy?).to eq(true)
      end
    end

    context 'with a non-Manual reconciler' do
      let(:payment_method) { create(:bank_transfer_gateway, preferences: { reconciler: 'manual', poll_interval_minutes: 15 }) }
      let(:fake_reconciler) { instance_double(Spree::BankTransfer::Reconcilers::Base) }

      before do
        allow(payment_method).to receive(:reconciler).and_return(fake_reconciler)
      end

      it 'is unhealthy when the reconciler itself reports unhealthy' do
        allow(fake_reconciler).to receive(:healthy?).and_return(false)
        payment_method.reconciler_state.update!(last_successful_run_at: Time.current)

        expect(payment_method.reconciler_healthy?).to eq(false)
      end

      it 'is unhealthy when the reconciler is healthy but the poll state is stale' do
        allow(fake_reconciler).to receive(:healthy?).and_return(true)
        payment_method.reconciler_state.update!(last_successful_run_at: 1.day.ago)

        expect(payment_method.reconciler_healthy?).to eq(false)
      end

      it 'is healthy when the reconciler is healthy and the poll state is fresh' do
        allow(fake_reconciler).to receive(:healthy?).and_return(true)
        payment_method.reconciler_state.update!(last_successful_run_at: Time.current)

        expect(payment_method.reconciler_healthy?).to eq(true)
      end
    end
  end
end
