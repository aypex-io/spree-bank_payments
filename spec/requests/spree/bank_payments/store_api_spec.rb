require 'spec_helper'

# A headless storefront's whole bank transfer checkout, through the Store
# API: list the methods, quote, place, then show the buyer how to pay.
RSpec.describe 'Bank transfer through the Store API', type: :request do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:cart) { bank_transfer_cart(gateway: gateway, price: 100) }
  let(:api_key) { create(:api_key, :publishable, store: cart.store) }
  let(:headers) { { 'x-spree-api-key' => api_key.token, 'x-spree-token' => cart.token } }
  let(:base) { "/api/v3/store/carts/#{cart.prefixed_id}" }

  def json_response
    JSON.parse(response.body)
  end

  def quote_bank_transfer
    post "#{base}/payment_sessions", params: { payment_method_id: gateway.prefixed_id }, headers: headers, as: :json
    json_response
  end

  def place_order
    session = quote_bank_transfer
    patch "#{base}/payment_sessions/#{session['id']}/complete", params: {}, headers: headers, as: :json
    post "#{base}/complete", headers: headers, as: :json
    [json_response, session]
  end

  it 'lists the discount on the payment method' do
    get base, headers: headers, as: :json

    bank_method = json_response['payment_methods'].find { |method| method['type'] == 'bank_transfer' }
    expect(bank_method['bank_transfer']['discount_percent']).to eq('3')
  end

  it 'adds nothing to other payment methods' do
    create(:check_payment_method, store: cart.store)
    get base, headers: headers, as: :json

    check = json_response['payment_methods'].find { |method| method['type'] != 'bank_transfer' }
    expect(check['bank_transfer']).to be_nil
  end

  it 'quotes the discounted amount when the session is created' do
    expect(quote_bank_transfer['external_data']['bank_transfer']['amount']).to eq('97.00')
  end

  it 'places the order with the payment pending' do
    order, = place_order

    expect(order['payment_status']).to eq('authorized')
  end

  describe 'the placed order' do
    let(:placed) { place_order }
    let(:payment) do
      get "/api/v3/store/orders/#{placed.first['id']}", headers: headers, as: :json
      json_response['payments'].first
    end

    it 'shows the reference' do
      expect(payment['bank_transfer']['reference']).to eq(placed.last['external_data']['bank_transfer']['reference'])
    end

    it 'shows the amount to transfer' do
      expect(payment['bank_transfer']['amount']).to eq('97.00')
    end

    it 'shows the bank details' do
      expect(payment['bank_transfer']['bank_details'].first['fields']).not_to be_empty
    end
  end
end
