require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::HealthController, type: :controller do
  render_views

  include_context 'API v3 Admin authenticated'

  let(:gateway) { create(:bank_transfer_gateway, store: store) }

  before { request.headers.merge!(headers) }

  def health
    get :show, params: { payment_method_id: gateway.prefixed_id }, as: :json
    json_response
  end

  it 'reports the reconciler health' do
    expect(health['health']).to eq('ok')
  end

  it 'names the reconciler' do
    expect(health['reconciler']).to eq('manual')
  end

  it 'gives the webhook URL to paste into the provider' do
    expect(health['webhook_url']).to eq(gateway.webhook_url)
  end

  it 'lists no currencies before an account is offered' do
    expect(health['offered_currencies']).to eq([])
  end

  it 'lists the offered currencies' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

    expect(health['offered_currencies']).to eq(['GBP'])
  end

  it "answers 404 for another store's payment method" do
    get :show, params: { payment_method_id: create(:bank_transfer_gateway, store: create(:store)).prefixed_id }, as: :json

    expect(response).to have_http_status(:not_found)
  end
end
