require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::TransfersController, type: :controller do
  render_views

  include_context 'API v3 Admin authenticated'

  let(:gateway) { create(:bank_transfer_gateway, store: store) }

  before { request.headers.merge!(headers) }

  def transfer(**attributes)
    create(:bank_transfer_incoming_transfer, { payment_method_id: gateway.id }.merge(attributes))
  end

  # A placed order big enough to take the session's payment: Spree refuses
  # a payment larger than the order total.
  def placed_session(amount: 25.00, **attributes)
    order = create(:completed_order_with_totals, currency: 'GBP', line_items_price: amount, store: store)
    create(:bank_transfer_payment_session,
           { order: order, payment_method: gateway, amount: amount, currency: 'GBP' }.merge(attributes))
  end

  def ids
    json_response['data'].map { |row| row['id'] }
  end

  describe 'GET index' do
    # The dashboard opens the queue filtered to unmatched; the API itself
    # applies no hidden filter, so "any status" means every transfer.
    it 'lists transfers in every state when the request does not filter on state' do
      unmatched = transfer
      ignored = transfer(state: 'ignored')

      get :index, as: :json

      expect(ids).to contain_exactly(unmatched.prefixed_id, ignored.prefixed_id)
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

  describe 'POST create' do
    let(:typed) do
      { payment_method_id: gateway.prefixed_id, amount: '25.00', currency: 'GBP',
        payer_name: 'Jane Doe', reference: 'ACME-NOTHING', occurred_at: '2026-11-02' }
    end

    def record(overrides = {})
      post :create, params: typed.merge(overrides), as: :json
    end

    it 'applies an exact match at once' do
      session = placed_session(amount: 25.00)

      record(reference: session.reference)

      expect(json_response['state']).to eq('applied')
    end

    it 'queues anything else' do
      record

      expect(json_response['state']).to eq('unmatched')
    end

    it 'answers 201' do
      record

      expect(response).to have_http_status(:created)
    end

    it 'records nothing twice when the form is resubmitted' do
      2.times { record }

      expect([json_response['already_recorded'], Spree::BankPayments::IncomingTransfer.count]).to eq([true, 1])
    end

    it 'refuses an amount that is not positive' do
      record(amount: '0.00')

      expect(json_response.dig('error', 'details').keys).to include('amount')
    end

    it "refuses another store's payment method" do
      other = create(:bank_transfer_gateway, store: create(:store))

      record(payment_method_id: other.prefixed_id)

      expect(json_response.dig('error', 'details').keys).to include('payment_method_id')
    end

    it 'refuses a JSON number for the amount' do
      record(amount: 25)

      expect(json_response.dig('error', 'code')).to eq('invalid_money_format')
    end
  end

  describe 'applying and ignoring' do
    # A 100.00 cart placed by bank transfer at 3% off: the order owes 97.00.
    let(:checkout_gateway) { create(:bank_transfer_gateway, store: store) }
    let(:placed) do
      store
      place_with_bank_transfer(bank_transfer_cart(gateway: checkout_gateway, price: 100), gateway: checkout_gateway)
    end
    let(:order) { placed.first }
    let(:session) { placed.last }

    def unmatched(amount: session.amount, **attributes)
      create(:bank_transfer_incoming_transfer,
             { payment_method_id: checkout_gateway.id, amount: amount, currency: session.currency,
               reference_raw: 'MISTYPED' }.merge(attributes))
    end

    def apply(transfer, **params)
      post :apply, params: { id: transfer.prefixed_id, payment_session_id: session.prefixed_id }.merge(params), as: :json
    end

    describe 'POST apply' do
      it 'applies a transfer to the session staff chose' do
        apply(unmatched)

        expect(order.reload.payment_status).to eq('paid')
      end

      it 'records who applied it' do
        transfer = unmatched
        apply(transfer)

        expect(transfer.reload.applied_by_id).to eq(admin_user.id)
      end

      it 'refuses a mismatched amount without confirmation' do
        apply(unmatched(amount: BigDecimal('90.00')))

        expect(json_response.dig('error', 'code')).to eq('amount_mismatch')
      end

      it 'says both amounts when it refuses a mismatch' do
        apply(unmatched(amount: BigDecimal('90.00')))

        expect(json_response.dig('error', 'details', 'session_amount')).to eq('97.00')
      end

      it 'applies a mismatched amount once confirmed' do
        apply(unmatched(amount: BigDecimal('90.00')), confirm_mismatch: true)

        expect(order.reload.payment_status).to eq('partially_paid')
      end

      it "refuses another gateway's session" do
        apply(unmatched(payment_method_id: create(:bank_transfer_gateway, store: store).id))

        expect(json_response.dig('error', 'code')).to eq('gateway_mismatch')
      end

      it "answers 404 for another store's session" do
        other_order = create(:completed_order_with_totals, store: create(:store), currency: 'GBP')
        other = create(:bank_transfer_payment_session, order: other_order, payment_method: checkout_gateway)

        post :apply, params: { id: unmatched.prefixed_id, payment_session_id: other.prefixed_id }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      it 'refuses to apply twice' do
        transfer = unmatched
        apply(transfer)
        apply(transfer)

        expect(json_response.dig('error', 'code')).to eq('already_applied')
      end

      it 'captures once when applied twice' do
        transfer = unmatched
        2.times { apply(transfer) }

        expect(Spree::PaymentCaptureEvent.where(payment: order.payments).count).to eq(1)
      end

      # Two requests at once: the other one applies the transfer after this
      # request loaded it, while it waits for the lock.
      it 'refuses a transfer applied while the request waited' do
        transfer = unmatched
        allow(Spree::BankPayments::ApplyTransfer).to receive(:call).and_wrap_original do |original, **kwargs|
          other_request = Spree::BankPayments::IncomingTransfer.find(kwargs[:transfer].id)
          original.call(transfer: other_request, payment_session: kwargs[:payment_session])
          original.call(**kwargs)
        end

        apply(transfer)

        expect(json_response.dig('error', 'code')).to eq('already_applied')
      end
    end

    describe 'POST ignore' do
      it 'ignores with a reason' do
        transfer = unmatched
        post :ignore, params: { id: transfer.prefixed_id, reason: 'Refunded to the payer' }, as: :json

        expect(transfer.reload.state).to eq('ignored')
      end

      it 'refuses to ignore without a reason' do
        post :ignore, params: { id: unmatched.prefixed_id, reason: ' ' }, as: :json

        expect(json_response.dig('error', 'details').keys).to include('reason')
      end

      it 'refuses to ignore an applied transfer' do
        transfer = unmatched
        apply(transfer)
        post :ignore, params: { id: transfer.prefixed_id, reason: 'Oops' }, as: :json

        expect(json_response.dig('error', 'code')).to eq('already_applied')
      end
    end
  end

  context 'with read_bank_payments only' do
    include_context 'API v3 Admin with custom permissions'

    let(:custom_permissions) { %w[read_bank_payments] }

    it 'may not apply a transfer' do
      transfer = create(:bank_transfer_incoming_transfer, payment_method_id: gateway.id)

      post :apply, params: { id: transfer.prefixed_id, payment_session_id: 'ps_nope' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'may not record a transfer' do
      post :create, params: { payment_method_id: gateway.prefixed_id, amount: '25.00', currency: 'GBP',
                              reference: 'ACME-X', occurred_at: '2026-11-02' }, as: :json

      expect(response).to have_http_status(:forbidden)
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
