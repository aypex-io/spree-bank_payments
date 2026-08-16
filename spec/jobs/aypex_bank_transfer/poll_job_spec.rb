require 'spec_helper'

RSpec.describe AypexBankTransfer::PollJob do
  let(:payment_method) { create(:bank_transfer_gateway) }

  before { payment_method }

  it 'records a successful run when the reconciler returns cleanly' do
    described_class.perform_now

    expect(payment_method.reconciler_state.reload.last_successful_run_at).to be_present
  end

  it 'records a failure and does not raise when the reconciler blows up, without wedging other payment methods' do
    other_payment_method = create(:bank_transfer_gateway)

    # Instance-specific stub: only the FIRST payment method's reconciler
    # raises. A rescue accidentally hoisted from #poll_one up to #perform
    # would pass a single-gateway version of this spec while wedging every
    # payment method processed after the first -- so a second gateway that
    # must still succeed is the property under test here.
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).to receive(:poll) do |instance, **|
      raise StandardError, 'credentials expired' if instance.payment_method.id == payment_method.id

      []
    end

    expect { described_class.perform_now }.not_to raise_error

    state = payment_method.reconciler_state.reload
    expect(state.last_error).to include('credentials expired')
    expect(state.consecutive_failures).to eq(1)
    expect(state.last_successful_run_at).to be_nil

    other_state = other_payment_method.reconciler_state.reload
    expect(other_state.last_successful_run_at).to be_present
  end

  it 'polls with since: derived from the last successful run minus the overlap window' do
    last_run = 3.hours.ago
    payment_method.reconciler_state.update!(last_successful_run_at: last_run)

    captured_since = nil
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).to receive(:poll) do |_instance, since:|
      captured_since = since
      []
    end

    described_class.perform_now

    # Hardcode the 2-hour literal rather than referencing
    # PollJob::OVERLAP -- asserting against the constant would make this
    # tautological and pass even if OVERLAP were deleted or changed.
    expect(captured_since).to be_within(1.second).of(last_run - 2.hours)
  end

  it 'polls with since: derived from a 7 day fallback minus the overlap window when never successful' do
    captured_since = nil
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).to receive(:poll) do |_instance, since:|
      captured_since = since
      []
    end

    described_class.perform_now

    expect(captured_since).to be_within(1.minute).of(7.days.ago - 2.hours)
  end

  it 'ingests every transfer the reconciler returns' do
    data = AypexBankTransfer::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-77', amount: 10.00,
      currency: 'GBP', reference: 'TKF-ZZZZZZ', payer_name: 'Jane Doe',
      occurred_at: Time.current, raw: {}
    )
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).
      to receive(:poll).and_return([data])

    expect { described_class.perform_now }.
      to change(AypexBankTransfer::IncomingTransfer, :count).by(1)
  end
end
