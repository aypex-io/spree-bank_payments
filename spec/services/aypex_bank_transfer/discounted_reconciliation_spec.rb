require 'spec_helper'

# The real production path: a discounted order is quoted through
# Gateway#create_payment_session (which now applies the discount before
# reading the amount -- see gateway_spec.rb), and the customer transfers
# exactly that quoted, discounted figure. Nothing else exercises this full
# round trip -- ingest_transfer_spec.rb and apply_transfer_spec.rb zero out
# the discount so they can pin an undiscounted amount, which is correct for
# what they test but leaves this path uncovered.
RSpec.describe 'reconciling a discounted bank-transfer order end-to-end' do
  it 'auto-applies a transfer for the discounted amount and reaches paid' do
    payment_method = create(:bank_transfer_gateway) # 3% in the factory
    order = create(:completed_order_with_totals, currency: 'GBP', line_items_price: 100.00, shipment_cost: 0)

    session = payment_method.create_payment_session(order: order)
    order.reload

    expect(session.amount).to eq(97.00)
    expect(order.total).to eq(97.00)

    transfer_data = AypexBankTransfer::TransferData.new(
      provider: 'test',
      provider_transaction_id: 'TX-DISCOUNTED-1',
      amount: session.amount,
      currency: session.currency,
      reference: session.external_id,
      payer_name: 'Jane Doe',
      occurred_at: Time.current,
      raw: {}
    )

    transfer = AypexBankTransfer::IngestTransfer.new(payment_method: payment_method, transfer_data: transfer_data).call

    expect(transfer).to be_applied
    expect(transfer.payment_session).to eq(session)
    expect(session.reload.status).to eq('completed')
    expect(order.reload.payment_state).to eq('paid')
  end
end
