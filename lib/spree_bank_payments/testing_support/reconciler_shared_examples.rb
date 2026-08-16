RSpec.shared_examples 'a bank transfer reconciler' do
  subject(:reconciler) { described_class.new(payment_method: payment_method) }

  it 'inherits the published contract' do
    expect(described_class.ancestors).to include(SpreeBankPayments::Reconcilers::Base)
  end

  it 'accepts a payment_method keyword' do
    expect(reconciler.payment_method).to eq(payment_method)
  end

  it 'returns an array from #poll' do
    result = reconciler.poll(since: 1.day.ago)

    # Element-type checking is deliberately NOT done here: a reconciler with
    # nothing to poll returns [], and `all(be_a(...))` passes vacuously
    # against an empty array. See the
    # 'a bank transfer reconciler that returns transfers' group below for
    # the assertion that actually inspects element types.
    expect(result).to be_an(Array)
  end

  it 'returns TransferData or nil from #parse_webhook' do
    result = reconciler.parse_webhook('{}', {})

    expect(result).to be_nil.or be_a(SpreeBankPayments::TransferData)
  end

  it 'answers #healthy? with a boolean' do
    expect([true, false]).to include(reconciler.healthy?)
  end

  it 'answers #configured? with a boolean' do
    expect([true, false]).to include(reconciler.configured?)
  end
end

# Provider gems MUST include this in addition to the group above. The base group
# cannot check element types — a reconciler with nothing to poll returns [], and
# every element assertion against an empty array passes vacuously.
RSpec.shared_examples 'a bank transfer reconciler that returns transfers' do
  # Host spec must define `reconciler` whose #poll returns at least one transfer.
  it 'returns TransferData instances with an identifying transaction id' do
    result = reconciler.poll(since: 1.day.ago)

    expect(result).not_to be_empty
    expect(result).to all(be_a(SpreeBankPayments::TransferData))
    expect(result.map(&:provider_transaction_id)).to all(be_present)
  end
end
