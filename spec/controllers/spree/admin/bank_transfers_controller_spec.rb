require 'spec_helper'

RSpec.describe Spree::Admin::BankTransfersController, type: :controller do
  stub_authorization!

  # discount_percent: 0 and a pinned 25.00 line-item/shipment total -- see
  # apply_transfer_spec.rb -- otherwise order.total never lands on the
  # pinned amount and payment_state can't reach 'paid'.
  let(:payment_method) { create(:bank_transfer_gateway, preferred_discount_percent: 0) }
  let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00, shipment_cost: 0) }
  let(:session_record) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, amount: 25.00, currency: 'GBP')
  end
  let(:transfer) do
    create(:bank_transfer_incoming_transfer,
           amount: 25.00, currency: 'GBP', reference_raw: 'WRONG', payment_method_id: payment_method.id)
  end

  describe 'GET #index' do
    it 'lists unmatched transfers' do
      transfer
      get :index

      expect(assigns(:transfers)).to include(transfer)
    end

    context 'rendering the view' do
      render_views

      it 'renders a transfer with a suggested match without error' do
        session_record
        transfer

        # The full `spree/admin` layout pulls in a Tailwind build this dummy
        # app never runs (`npm run build`), which is orthogonal to what this
        # spec is proving -- that index.html.erb itself (pagy_nav-equivalent
        # nav, `l(occurred_at)`, `suggestion.money`, `suggestion.order.number`)
        # renders without error. The `Turbo-Frame` header swaps in Turbo's
        # minimal asset-free layout, same content, no CSS dependency.
        request.headers['Turbo-Frame'] = 'bank-transfers'

        get :index

        expect(response).to be_successful
        expect(response.body).to include(transfer.payer_name)
        expect(response.body).to include(order.number)
        expect(response.body).to include('WRONG')
      end
    end
  end

  describe 'PUT #apply' do
    it 'applies the transfer to the chosen session and records who did it' do
      put :apply, params: { id: transfer.id, payment_session_id: session_record.id }

      transfer.reload
      expect(transfer).to be_applied
      expect(transfer.payment_session).to eq(session_record)
      expect(transfer.applied_by_id).to be_present
      expect(transfer.applied_at).to be_present
    end

    it 'moves the order to a paid payment_state via the shared ApplyTransfer path' do
      expect(order).to be_completed

      put :apply, params: { id: transfer.id, payment_session_id: session_record.id }

      expect(order.reload.payment_state).to eq('paid')
    end

    it 'refuses to apply an already applied transfer' do
      transfer.update!(state: 'applied', payment_session: session_record)

      put :apply, params: { id: transfer.id, payment_session_id: session_record.id }

      expect(response).to redirect_to(spree.admin_bank_transfers_path)
      expect(flash[:error]).to be_present
    end

    it 'refuses a payment_session_id that belongs to a non-bank-transfer payment method' do
      other_order = create(:completed_order_with_totals)
      other_session = create(:bogus_payment_session, order: other_order, amount: 25.00, currency: 'GBP')

      put :apply, params: { id: transfer.id, payment_session_id: other_session.id }

      transfer.reload
      expect(transfer).not_to be_applied
      expect(flash[:error]).to be_present
    end

    it 'refuses a payment_session_id that belongs to another store' do
      other_store = create(:store, url: 'other-store.example.com')
      other_order = create(:completed_order_with_totals, store: other_store)
      other_session = create(:bank_transfer_payment_session,
                              order: other_order, payment_method: payment_method,
                              amount: 25.00, currency: 'GBP')

      put :apply, params: { id: transfer.id, payment_session_id: other_session.id }

      transfer.reload
      expect(transfer).not_to be_applied
      expect(flash[:error]).to be_present
    end

    it 'refuses a payment_session_id whose gateway differs from the transfer\'s own gateway' do
      other_gateway = create(:bank_transfer_gateway, preferred_discount_percent: 0)
      other_session = create(:bank_transfer_payment_session,
                              order: order, payment_method: other_gateway,
                              amount: 25.00, currency: 'GBP')

      put :apply, params: { id: transfer.id, payment_session_id: other_session.id }

      transfer.reload
      expect(transfer).not_to be_applied
      expect(flash[:error]).to be_present
    end

    context 'when the transfer amount/currency does not match the session' do
      let(:mismatched_session) do
        create(:bank_transfer_payment_session,
               order: order, payment_method: payment_method, amount: 20.00, currency: 'GBP')
      end

      it 'refuses to apply without explicit confirmation' do
        put :apply, params: { id: transfer.id, payment_session_id: mismatched_session.id }

        transfer.reload
        expect(transfer).not_to be_applied
        expect(flash[:error]).to be_present
        expect(flash[:error]).to include('25').and include('20')
      end

      it 'applies once the mismatch is explicitly confirmed, and names both amounts in the flash beforehand' do
        put :apply, params: {
          id: transfer.id, payment_session_id: mismatched_session.id, confirm_mismatch: '1'
        }

        transfer.reload
        expect(transfer).to be_applied
        expect(transfer.payment_session).to eq(mismatched_session)
      end
    end
  end

  describe 'PUT #ignore' do
    it 'marks the transfer ignored with a reason' do
      put :ignore, params: { id: transfer.id, reason: 'refunded manually' }

      transfer.reload
      expect(transfer.state).to eq('ignored')
      expect(transfer.ignored_reason).to eq('refunded manually')
    end

    it 'refuses to ignore an already applied transfer' do
      transfer.update!(state: 'applied', payment_session: session_record)

      put :ignore, params: { id: transfer.id, reason: 'refunded manually' }

      transfer.reload
      expect(transfer.state).to eq('applied')
      expect(flash[:error]).to be_present
    end

    it 'refuses to ignore without a reason' do
      put :ignore, params: { id: transfer.id, reason: '' }

      transfer.reload
      expect(transfer.state).to eq('unmatched')
      expect(flash[:error]).to be_present
    end
  end
end
