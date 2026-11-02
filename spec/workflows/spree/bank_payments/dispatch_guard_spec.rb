require 'spec_helper'

# The gateway captures "at checkout", so Spree's own dispatch rule holds an
# unpaid bank transfer order: its pending payment does not count as one
# staff have taken charge of collecting.
RSpec.describe 'Dispatching a bank transfer order' do
  let(:gateway) { create(:bank_transfer_gateway) }
  let(:placed) { place_with_bank_transfer(stock!(bank_transfer_cart(gateway: gateway, price: 100)), gateway: gateway) }
  let(:order) { placed.first }
  let(:session) { placed.last }

  def fulfil(**options)
    Spree.fulfillment_fulfill_workflow.call(fulfillment: order.fulfillments.first, **options)
  end

  it 'refuses to dispatch an unpaid order' do
    expect(fulfil.error.to_s).to include(I18n.t('spree.fulfillments.errors.order_not_paid'))
  end

  it 'dispatches an unpaid one when staff force it' do
    expect(fulfil(force: true)).to be_success
  end

  it 'dispatches once the transfer is applied' do
    pending 'ApplyTransfer is ported in Task 7'
    transfer = create(:bank_transfer_incoming_transfer, payment_method: gateway, amount: session.amount,
                                                        currency: session.currency, reference_raw: session.reference)
    Spree::BankPayments::ApplyTransfer.call(transfer: transfer, payment_session: session)

    expect(fulfil).to be_success
  end
end
