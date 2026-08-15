RSpec.shared_examples 'a bank transfer reconciler' do
  subject(:reconciler) { described_class.new(payment_method: payment_method) }

  it 'inherits the published contract' do
    expect(described_class.ancestors).to include(AypexBankTransfer::Reconcilers::Base)
  end

  it 'accepts a payment_method keyword' do
    expect(reconciler.payment_method).to eq(payment_method)
  end

  it 'returns an array of TransferData from #poll' do
    result = reconciler.poll(since: 1.day.ago)

    expect(result).to be_an(Array)
    expect(result).to all(be_a(AypexBankTransfer::TransferData))
  end

  it 'returns TransferData or nil from #parse_webhook' do
    result = reconciler.parse_webhook('{}', {})

    expect(result).to be_nil.or be_a(AypexBankTransfer::TransferData)
  end

  it 'answers #healthy? with a boolean' do
    expect([true, false]).to include(reconciler.healthy?)
  end

  it 'answers #configured? with a boolean' do
    expect([true, false]).to include(reconciler.configured?)
  end
end
