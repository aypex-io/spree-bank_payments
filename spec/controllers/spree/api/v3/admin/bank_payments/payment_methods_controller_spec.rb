require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::PaymentMethodsController, type: :controller do
  render_views

  let!(:gateway) { create(:bank_transfer_gateway, store: store, name: 'Bank transfer') }

  before { request.headers.merge!(headers) }

  def ids
    get :index, as: :json
    json_response['data'].pluck('id')
  end

  context 'with full access' do
    include_context 'API v3 Admin authenticated'

    it "lists the store's bank transfer payment methods" do
      expect(ids).to eq([gateway.prefixed_id])
    end

    it 'names each one' do
      get :index, as: :json

      expect(json_response['data'].first['name']).to eq('Bank transfer')
    end

    it 'leaves out other kinds of payment method' do
      create(:check_payment_method, store: store)

      expect(ids).to eq([gateway.prefixed_id])
    end

    it "leaves out another store's" do
      create(:bank_transfer_gateway, store: create(:store))

      expect(ids).to eq([gateway.prefixed_id])
    end
  end

  # Recording a transfer picks one of these. A bank clerk's role grants the
  # bank transfers permission, not the store's settings.
  context 'with write_bank_payments only' do
    include_context 'API v3 Admin with custom permissions'

    let(:custom_permissions) { %w[write_bank_payments] }

    it 'lists them' do
      expect(ids).to eq([gateway.prefixed_id])
    end
  end

  context 'without the bank transfers permission' do
    include_context 'API v3 Admin with custom permissions'

    let(:custom_permissions) { %w[read_orders] }

    it 'is forbidden' do
      get :index, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
