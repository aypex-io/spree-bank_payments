require 'spec_helper'

# On a pooled account the coordinates are shared with other customers of the
# provider, so the reference is the ONLY thing separating two payers. Matching
# on amount and currency alone would credit the wrong order.
#
# The current matcher already demands an exact reference for every account, so
# these pass on the day they are written. That is the point: they are a lock,
# not a fix. If someone later adds a fuzzy or amount-only fallback, this file is
# what stops it reaching a pooled account.
RSpec.describe 'auto-apply against a pooled account' do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let!(:account) do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'USD',
                                         offered: true, pooled: true, provider_account_id: 'acc_pool')
  end
  let!(:session) do
    place_with_bank_transfer(bank_transfer_cart(gateway: payment_method, price: 100), gateway: payment_method).last
  end

  def ingest(reference:)
    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: SecureRandom.uuid,
      provider_account_id: 'acc_pool', amount: session.amount, currency: session.currency,
      reference: reference, payer_name: 'Someone Else', occurred_at: Time.current, raw: {}
    )
    Spree::BankPayments::IngestTransfer.new(payment_method: payment_method, transfer_data: data).call
  end

  it 'applies when the reference matches exactly' do
    expect(ingest(reference: session.external_id)).to be_applied
  end

  it 'refuses a transfer with no reference, even though amount and currency agree' do
    expect(ingest(reference: '')).not_to be_applied
  end

  it 'refuses a near-miss reference, even though amount and currency agree' do
    expect(ingest(reference: "#{session.external_id}X")).not_to be_applied
  end
end
