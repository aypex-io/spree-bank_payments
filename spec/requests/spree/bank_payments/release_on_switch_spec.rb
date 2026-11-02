require 'spec_helper'
require 'spree/api/testing_support/v3/base'

# Another method's session or payment is sized from the cart total when it
# is created. A buyer who picked bank transfer and then changed their mind
# must be charged the undiscounted total by the method they changed to.
RSpec.describe 'Switching away from bank transfer', type: :request do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:cart) { bank_transfer_cart(gateway: gateway, price: 100) }
  let(:api_key) { create(:api_key, :publishable, store: cart.store) }
  let(:headers) { { 'x-spree-api-key' => api_key.token, 'x-spree-token' => cart.token } }
  let(:cards) { create(:credit_card_payment_method, store: cart.store) }
  let(:check) { create(:check_payment_method, store: cart.store) }

  before { gateway.create_payment_session(order: cart) }

  def json_response
    JSON.parse(response.body)
  end

  it "creates another method's session for the undiscounted total" do
    post "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions",
         params: { payment_method_id: cards.prefixed_id }, headers: headers, as: :json

    expect(json_response['amount']).to eq('100.00')
  end

  it 'creates a direct payment for the undiscounted total' do
    post "/api/v3/store/carts/#{cart.prefixed_id}/payments",
         params: { payment_method_id: check.prefixed_id }, headers: headers, as: :json

    expect(json_response['amount']).to eq('100.00')
  end

  it 'leaves no bank discount rows behind' do
    post "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions",
         params: { payment_method_id: cards.prefixed_id }, headers: headers, as: :json

    expect(bank_transfer_discounts(cart)).to be_empty
  end

  it 'keeps the discount when the buyer re-selects bank transfer' do
    post "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions",
         params: { payment_method_id: gateway.prefixed_id }, headers: headers, as: :json

    expect(json_response['amount']).to eq('97.00')
  end

  it 'refuses to complete the released bank session' do
    bank_session = Spree::PaymentSessions::BankTransfer.find_by!(cart: cart)
    post "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions",
         params: { payment_method_id: cards.prefixed_id }, headers: headers, as: :json

    patch "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions/#{bank_session.prefixed_id}/complete",
          params: {}, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
  end

  # A session of another method created before bank transfer was chosen was
  # sized at the full total. Completing or updating it means the buyer is
  # paying that way after all.
  describe "completing another method's earlier session" do
    let!(:card_session) { cards.create_payment_session(order: cart, amount: BigDecimal('100.00')) }

    before { gateway.create_payment_session(order: cart) }

    it 'takes the bank transfer discount off' do
      patch "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions/#{card_session.prefixed_id}/complete",
            params: {}, headers: headers, as: :json

      expect(bank_transfer_discounts(cart)).to be_empty
    end

    it 'takes it off when that session is updated' do
      patch "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions/#{card_session.prefixed_id}",
            params: {}, headers: headers, as: :json

      expect(bank_transfer_discounts(cart)).to be_empty
    end
  end

  # A request Spree itself refuses must not have released anything.
  it 'leaves bank transfer selected when the other method is not available' do
    cards.update!(active: false)

    post "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions",
         params: { payment_method_id: cards.prefixed_id }, headers: headers, as: :json

    expect(bank_transfer_discounts(cart)).not_to be_empty
  end
end
