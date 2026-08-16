require 'spec_helper'

RSpec.describe 'spree/bank_payments/admin/_order_panel', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  it 'shows the reference and awaiting status for an unpaid order' do
    session = payment_method.create_payment_session(order: order)

    render partial: 'spree/bank_payments/admin/order_panel', locals: { order: order }

    expect(rendered).to include(session.reference)
    expect(rendered).to include('Awaiting transfer')
  end

  it 'renders nothing for an order with no bank transfer session' do
    render partial: 'spree/bank_payments/admin/order_panel', locals: { order: order }

    expect(rendered.strip).to be_empty
  end

  # A superseded session is canceled with expires_at in the past. Reading the
  # time-based `expired?` predicate first badged a card-paid order as "Expired".
  it 'badges a superseded session as superseded, not expired' do
    session = payment_method.create_payment_session(order: order)
    session.update!(expires_at: 2.days.ago)
    session.cancel!

    render partial: 'spree/bank_payments/admin/order_panel', locals: { order: order }

    expect(rendered).to include('Superseded')
    expect(rendered).not_to include('Expired')
  end

  it 'badges a swept session as expired' do
    session = payment_method.create_payment_session(order: order)
    session.update!(expires_at: 2.days.ago)
    session.expire!

    render partial: 'spree/bank_payments/admin/order_panel', locals: { order: order }

    expect(rendered).to include('Expired')
    expect(rendered).not_to include('Superseded')
  end

  # `.open` still matches a pending session past its expiry, so a payment can
  # still be auto-applied to it. The badge must not claim otherwise.
  it 'still shows awaiting transfer for a pending session the sweeper has not reached' do
    session = payment_method.create_payment_session(order: order)
    session.update!(expires_at: 2.days.ago)

    render partial: 'spree/bank_payments/admin/order_panel', locals: { order: order }

    expect(rendered).to include('Awaiting transfer')
    expect(rendered).not_to include('Expired')
  end
end
