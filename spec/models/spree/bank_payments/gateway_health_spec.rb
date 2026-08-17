require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway do
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
      let(:fake_reconciler) { instance_double(Spree::BankPayments::Reconcilers::Base) }

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

  describe '#health' do
    let(:payment_method) { create(:bank_transfer_gateway) }
    let(:order) { create(:order_with_line_items, currency: 'GBP') }

    before { create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true) }

    # available_for_order? runs on every checkout render. A network call here
    # would put a bank's latency on the storefront's critical path, so this
    # reads only what the poll job persisted.
    it 'never asks the reconciler, so checkout cannot make a network call' do
      expect(payment_method.reconciler).not_to receive(:health)

      payment_method.health
    end

    it 'is :consent_revoked when that is what the poll job recorded' do
      payment_method.reconciler_state.update!(health_status: 'consent_revoked')

      expect(payment_method.health).to eq(:consent_revoked)
    end

    it 'withdraws the payment method from checkout when consent is revoked' do
      payment_method.reconciler_state.update!(health_status: 'consent_revoked')

      expect(payment_method.available_for_order?(order)).to be(false)
    end

    # A brief provider outage must not pull bank transfer off the storefront:
    # the transfers still arrive and reconcile once the provider returns.
    it 'keeps offering at checkout while merely transient' do
      payment_method.reconciler_state.update!(health_status: 'transient')

      expect(payment_method.available_for_order?(order)).to be(true)
    end

    it 'is always :ok for the manual reconciler, which never talks to anything' do
      expect(payment_method.health).to eq(:ok)
    end
  end
end
