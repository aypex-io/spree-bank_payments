require 'spec_helper'

RSpec.describe AypexBankTransfer::ReconcilerState do
  include ActiveSupport::Testing::TimeHelpers

  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:reconciler_state) { payment_method.reconciler_state }
  let(:poll_interval_minutes) { 15 }

  describe '#healthy?' do
    context 'when last_successful_run_at is nil' do
      it 'is unhealthy' do
        reconciler_state.update!(last_successful_run_at: nil)

        expect(reconciler_state.healthy?(poll_interval_minutes)).to eq(false)
      end
    end

    context 'when last_successful_run_at is inside the three-interval window' do
      it 'is healthy' do
        reconciler_state.update!(last_successful_run_at: 10.minutes.ago)

        expect(reconciler_state.healthy?(poll_interval_minutes)).to eq(true)
      end
    end

    context 'when last_successful_run_at is outside the three-interval window' do
      it 'is unhealthy' do
        reconciler_state.update!(last_successful_run_at: 46.minutes.ago)

        expect(reconciler_state.healthy?(poll_interval_minutes)).to eq(false)
      end
    end

    context 'at the exact boundary of the three-interval window' do
      it 'is unhealthy when exactly at the boundary (not strictly greater than)' do
        travel_to(Time.current) do
          reconciler_state.update!(last_successful_run_at: (poll_interval_minutes * 3).minutes.ago)

          expect(reconciler_state.healthy?(poll_interval_minutes)).to eq(false)
        end
      end

      it 'is healthy one second inside the boundary' do
        travel_to(Time.current) do
          reconciler_state.update!(last_successful_run_at: ((poll_interval_minutes * 3).minutes.ago + 1.second))

          expect(reconciler_state.healthy?(poll_interval_minutes)).to eq(true)
        end
      end
    end
  end

  describe '#record_success!' do
    it 'sets last_successful_run_at, clears last_error, and resets consecutive_failures' do
      reconciler_state.update!(last_error: 'boom', consecutive_failures: 4)

      reconciler_state.record_success!

      expect(reconciler_state.last_successful_run_at).to be_present
      expect(reconciler_state.last_error).to be_nil
      expect(reconciler_state.consecutive_failures).to eq(0)
    end
  end

  describe '#record_failure!' do
    it 'increments consecutive_failures and records the error' do
      reconciler_state.update!(consecutive_failures: 1)

      reconciler_state.record_failure!(StandardError.new('connection refused'))

      expect(reconciler_state.consecutive_failures).to eq(2)
      expect(reconciler_state.last_error).to eq('connection refused')
    end
  end
end
