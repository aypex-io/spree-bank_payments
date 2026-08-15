require 'spec_helper'
require 'aypex_bank_transfer/testing_support/reconciler_shared_examples'

RSpec.describe AypexBankTransfer::Reconcilers::Manual do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'

  it 'is always healthy because it never polls' do
    expect(described_class.new(payment_method: payment_method)).to be_healthy
  end

  it 'returns no transfers when polled' do
    expect(described_class.new(payment_method: payment_method).poll(since: 1.day.ago)).to eq([])
  end
end
