require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::OrdersController, type: :controller do
  render_views

  include_context 'API v3 Admin authenticated'

  let(:gateway) { create(:bank_transfer_gateway, store: store) }
  let(:placed) do
    store
    place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway)
  end
  let(:order) { placed.first }
  let(:session) { placed.last }

  before { request.headers.merge!(headers) }

  it 'shows the bank transfer sessions of an order' do
    get :show, params: { id: order.prefixed_id }, as: :json

    expect(json_response['sessions'].map { |row| row['reference'] }).to eq([session.reference])
  end

  it 'quotes each session as the buyer was told' do
    get :show, params: { id: order.prefixed_id }, as: :json

    expect(json_response['sessions'].first['amount']).to eq('97.00')
  end

  it 'shows the transfer applied to it' do
    transfer = create(:bank_transfer_incoming_transfer, payment_method_id: gateway.id, amount: session.amount,
                                                        currency: session.currency, reference_raw: session.reference)
    Spree::BankPayments::ApplyTransfer.call(transfer: transfer, payment_session: session)

    get :show, params: { id: order.prefixed_id }, as: :json

    expect(json_response['transfers'].map { |row| row['id'] }).to eq([transfer.prefixed_id])
  end

  it 'answers with empty lists for an order paid another way' do
    other = create(:completed_order_with_totals, store: store)

    get :show, params: { id: other.prefixed_id }, as: :json

    expect([json_response['sessions'], json_response['transfers']]).to eq([[], []])
  end

  it "answers 404 for another store's order" do
    other = create(:completed_order_with_totals, store: create(:store))

    get :show, params: { id: other.prefixed_id }, as: :json

    expect(response).to have_http_status(:not_found)
  end
end
