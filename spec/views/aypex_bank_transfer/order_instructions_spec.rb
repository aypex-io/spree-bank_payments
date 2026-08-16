require 'spec_helper'

RSpec.describe 'aypex_bank_transfer/_order_instructions', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let(:payment_session) { payment_method.create_payment_session(order: order) }

  it 'shows the reference prominently' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include(payment_session.reference)
  end

  it 'shows the bank details' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('GB00TEST00000000000000')
  end

  it 'never uses surcharge language' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered.downcase).not_to include('surcharge')
    expect(rendered.downcase).not_to include('fee')
  end
end
