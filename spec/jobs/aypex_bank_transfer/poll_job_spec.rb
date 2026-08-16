require 'spec_helper'

RSpec.describe AypexBankTransfer::PollJob do
  let(:payment_method) { create(:bank_transfer_gateway) }

  before { payment_method }

  it 'records a successful run when the reconciler returns cleanly' do
    described_class.perform_now

    expect(payment_method.reconciler_state.reload.last_successful_run_at).to be_present
  end

  it 'records a failure and does not raise when the reconciler blows up' do
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).
      to receive(:poll).and_raise(StandardError, 'credentials expired')

    expect { described_class.perform_now }.not_to raise_error

    state = payment_method.reconciler_state.reload
    expect(state.last_error).to include('credentials expired')
    expect(state.consecutive_failures).to eq(1)
    expect(state.last_successful_run_at).to be_nil
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
