require 'spec_helper'

# The production path end to end: a buyer is quoted the discounted amount at
# checkout, places the order, and transfers exactly that figure.
RSpec.describe 'reconciling a discounted bank transfer order end to end' do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:placed) { place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway) }

  def ingest(session)
    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-DISCOUNTED-1',
      amount: session.amount, currency: session.currency, reference: session.reference,
      payer_name: 'Jane Doe', occurred_at: Time.current, raw: {}
    )
    Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call
  end

  it 'quotes the discounted amount' do
    expect(placed.last.amount).to eq(BigDecimal('97.00'))
  end

  it 'auto-applies a transfer for that amount' do
    expect(ingest(placed.last)).to be_applied
  end

  it 'leaves the order paid' do
    order, session = placed
    ingest(session)

    expect(order.reload.payment_status).to eq('paid')
  end
end
