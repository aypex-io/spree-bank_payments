require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::TransfersController, type: :controller do
  render_views

  include_context 'API v3 Admin authenticated'

  let(:gateway) { create(:bank_transfer_gateway, store: store) }

  before { request.headers.merge!(headers) }

  def transfer(**attributes)
    create(:bank_transfer_incoming_transfer, { payment_method_id: gateway.id }.merge(attributes))
  end

  def placed_session(amount: 25.00, **attributes)
    order = create(:order, state: 'complete', currency: 'GBP', store: store)
    create(:bank_transfer_payment_session,
           { order: order, payment_method: gateway, amount: amount, currency: 'GBP' }.merge(attributes))
  end

  def ids
    json_response['data'].map { |row| row['id'] }
  end

  describe 'GET index' do
    it 'lists unmatched transfers by default' do
      unmatched = transfer
      transfer(state: 'ignored')

      get :index, as: :json

      expect(ids).to eq([unmatched.prefixed_id])
    end

    it 'filters by state' do
      ignored = transfer(state: 'ignored')

      get :index, params: { q: { state_eq: 'ignored' } }, as: :json

      expect(ids).to eq([ignored.prefixed_id])
    end

    it "excludes another store's transfers" do
      other_gateway = create(:bank_transfer_gateway, store: create(:store))
      create(:bank_transfer_incoming_transfer, payment_method_id: other_gateway.id)

      get :index, as: :json

      expect(ids).to be_empty
    end

    it 'paginates' do
      3.times { transfer }

      get :index, params: { limit: 2 }, as: :json

      expect([ids.size, json_response['meta']['count']]).to eq([2, 3])
    end

    it 'writes amounts with the currency decimals' do
      transfer(amount: 25)

      get :index, as: :json

      expect(json_response['data'].first['amount']).to eq('25.00')
    end
  end

  describe 'GET show' do
    it 'shows a transfer' do
      shown = transfer

      get :show, params: { id: shown.prefixed_id }, as: :json

      expect(json_response['reference']).to eq(shown.reference_raw)
    end

    it "answers 404 for another store's transfer" do
      other = create(:bank_transfer_incoming_transfer, payment_method_id: create(:bank_transfer_gateway, store: create(:store)).id)

      get :show, params: { id: other.prefixed_id }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET suggestions' do
    it 'suggests the exact match first' do
      exact = placed_session(amount: 25.00)
      placed_session(amount: 99.00)

      get :suggestions, params: { id: transfer(amount: 25.00, reference_raw: 'NOTHING').prefixed_id }, as: :json

      expect(ids.first).to eq(exact.prefixed_id)
    end

    it 'marks the exact match' do
      placed_session(amount: 25.00)

      get :suggestions, params: { id: transfer(amount: 25.00, reference_raw: 'NOTHING').prefixed_id }, as: :json

      expect(json_response['data'].first['exact_match']).to be(true)
    end

    it "names the suggestion's order" do
      session = placed_session(amount: 25.00)

      get :suggestions, params: { id: transfer(amount: 25.00, reference_raw: 'NOTHING').prefixed_id }, as: :json

      expect(json_response['data'].first['order']['number']).to eq(session.order.number)
    end
  end

  context 'without read_bank_payments' do
    include_context 'API v3 Admin with custom permissions'

    let(:custom_permissions) { [] }

    it 'answers 403' do
      get :index, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
