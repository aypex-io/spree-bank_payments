require 'spec_helper'

RSpec.describe 'aypex_bank_transfer/admin/_order_panel', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  it 'shows the reference and awaiting status for an unpaid order' do
    session = payment_method.create_payment_session(order: order)

    render partial: 'aypex_bank_transfer/admin/order_panel', locals: { order: order }

    expect(rendered).to include(session.reference)
    expect(rendered).to include('Awaiting transfer')
  end

  it 'renders nothing for an order with no bank transfer session' do
    render partial: 'aypex_bank_transfer/admin/order_panel', locals: { order: order }

    expect(rendered.strip).to be_empty
  end
end
