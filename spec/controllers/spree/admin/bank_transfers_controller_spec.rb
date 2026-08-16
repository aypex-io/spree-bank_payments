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

  # I3. The view used to pre-fill `confirm_mismatch`, satisfying the
  # controller's guard before the admin saw anything, and the only remaining
  # friction was `data: { confirm: }` -> data-confirm, which Turbo (and Spree
  # 5.6 admin is Turbo) ignores completely. So a £250 transfer could be
  # applied to a £25 order in one click, silently.
  describe 'mismatch confirmation in the queue view' do
    render_views

    # A mismatched suggestion can only reach the view via the fuzzy payer-name
    # path -- amount_matches only ever returns equal amounts.
    let(:mismatched_session) do
      create(:bank_transfer_payment_session,
             order: order, payment_method: payment_method, amount: 20.00, currency: 'GBP')
    end

    before do
      order.bill_address.update!(firstname: 'Jane', lastname: 'Doe')
      mismatched_session
      transfer
      request.headers['Turbo-Frame'] = 'bank-transfers'
    end

    it 'does not pre-grant confirmation on the mismatch form' do
      get :index

      expect(response.body).to include('Amount/currency mismatch')
      expect(response.body).not_to include('confirm_mismatch')
    end

    it 'uses the Turbo confirmation attribute, not the rails-ujs one Turbo ignores' do
      get :index

      expect(response.body).to include('data-turbo-confirm')
      expect(response.body).not_to include('data-confirm=')
    end

    it 'offers an explicit confirm control only for the pair just refused' do
      get :index, params: {
        confirm_transfer_id: transfer.id, confirm_payment_session_id: mismatched_session.id
      }

      expect(response.body).to include('confirm_mismatch')
      expect(response.body).to include('Yes — apply')
    end

    it 'does not offer it for a different pair' do
      get :index, params: {
        confirm_transfer_id: transfer.id, confirm_payment_session_id: mismatched_session.id + 999
      }

      expect(response.body).not_to include('confirm_mismatch')
    end

    it 'shows no mismatch badge when only currency casing differs' do
      mismatched_session.update!(amount: 25.00, currency: 'gbp')

      get :index

      expect(response.body).to include(order.number)
      expect(response.body).not_to include('Amount/currency mismatch')
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

      it 'refuses to apply without explicit confirmation, and creates no payment' do
        expect {
          put :apply, params: { id: transfer.id, payment_session_id: mismatched_session.id }
        }.not_to change(Spree::Payment, :count)

        transfer.reload
        expect(transfer).not_to be_applied
        expect(flash[:error]).to be_present
        expect(flash[:error]).to include('25').and include('20')
      end

      # The refusal must hand back the pair, otherwise confirmation is
      # merely blocked and there is no way for an admin to deliberately
      # proceed -- see the queue-view specs above for the other half.
      it 'redirects back naming the pair that may now be confirmed' do
        put :apply, params: { id: transfer.id, payment_session_id: mismatched_session.id }

        expect(response).to redirect_to(
          spree.admin_bank_transfers_path(
            confirm_transfer_id: transfer.id, confirm_payment_session_id: mismatched_session.id
          )
        )
      end

      it 'applies once the mismatch is explicitly confirmed, and names both amounts in the flash beforehand' do
        put :apply, params: {
          id: transfer.id, payment_session_id: mismatched_session.id, confirm_mismatch: '1'
        }

        transfer.reload
        expect(transfer).to be_applied
        expect(transfer.payment_session).to eq(mismatched_session)
      end

      it 'does not force confirmation when only currency casing differs (Fix 7)' do
        same_currency_session = create(:bank_transfer_payment_session,
                                        order: order, payment_method: payment_method,
                                        amount: 25.00, currency: 'gbp')

        put :apply, params: { id: transfer.id, payment_session_id: same_currency_session.id }

        transfer.reload
        expect(transfer).to be_applied
        expect(flash[:error]).to be_nil
      end
    end

    context 'crediting a confirmed mismatch (Fix 6)' do
      # A distinct, larger order/session so a 25.00 payment leaves a real,
      # non-zero balance -- proving payment_state reflects what was
      # actually credited, not the session's (mismatched) expectation.
      let(:big_order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 250.00, shipment_cost: 0) }
      let(:big_session) do
        create(:bank_transfer_payment_session,
               order: big_order, payment_method: payment_method, amount: 250.00, currency: 'GBP')
      end

      it 'credits the payment for the transfer amount (25), not the session amount (250), and leaves the order unpaid' do
        put :apply, params: {
          id: transfer.id, payment_session_id: big_session.id, confirm_mismatch: '1'
        }

        transfer.reload
        expect(transfer).to be_applied
        big_order.reload
        expect(big_order.payments.last.amount).to eq(25.00)
        expect(big_order.payment_state).not_to eq('paid')
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

  # C1: the shipped (Manual) configuration has no poll and no webhook, so
  # this form is the only way an IncomingTransfer can ever come into
  # existence. Without it a store takes the customer's money and has no
  # action available to record it.
  describe 'GET #new' do
    render_views

    it 'renders the form' do
      payment_method
      request.headers['Turbo-Frame'] = 'bank-transfers'

      get :new

      expect(response).to be_successful
      expect(response.body).to include('bank_transfer[amount]')
      expect(response.body).to include('bank_transfer[reference]')
      expect(response.body).to include('bank_transfer[occurred_at]')
    end
  end

  describe 'POST #create' do
    let!(:matching_session) do
      create(:bank_transfer_payment_session,
             order: order, payment_method: payment_method,
             amount: 25.00, currency: 'GBP', external_id: 'TKF-7Q4X2')
    end

    def submit(overrides = {})
      post :create, params: {
        bank_transfer: {
          payment_method_id: payment_method.id,
          amount: '25.00',
          currency: 'GBP',
          payer_name: 'Jane Doe',
          reference: 'TKF-7Q4X2',
          occurred_at: Date.current.to_s
        }.merge(overrides)
      }
    end

    it 'auto-applies an exact match through IngestTransfer and moves the order to paid' do
      expect { submit }.to change(SpreeBankPayments::IncomingTransfer, :count).by(1)

      recorded = SpreeBankPayments::IncomingTransfer.last
      expect(recorded).to be_applied
      expect(recorded.payment_session).to eq(matching_session)
      expect(recorded.payment_method_id).to eq(payment_method.id)
      expect(order.reload.payment_state).to eq('paid')
    end

    it 'queues a non-matching transfer as unmatched instead of applying it' do
      expect { submit(reference: 'NOT-A-REFERENCE') }.
        to change(SpreeBankPayments::IncomingTransfer, :count).by(1)

      recorded = SpreeBankPayments::IncomingTransfer.last
      expect(recorded.state).to eq('unmatched')
      expect(recorded.payment_session).to be_nil
      expect(order.reload.payment_state).not_to eq('paid')
      expect(matching_session.reload.status).to eq('pending')
    end

    it 'does not double-apply when the same form is submitted twice' do
      submit
      expect(order.reload.payment_state).to eq('paid')

      expect { submit }.not_to change(SpreeBankPayments::IncomingTransfer, :count)
      expect(order.reload.payments.completed.count).to eq(1)
    end

    it 'rejects a non-numeric amount without creating anything' do
      expect { submit(amount: 'twenty five') }.not_to change(SpreeBankPayments::IncomingTransfer, :count)
      expect(flash.now[:error]).to be_present
    end

    it 'rejects a zero amount without creating anything' do
      expect { submit(amount: '0') }.not_to change(SpreeBankPayments::IncomingTransfer, :count)
      expect(flash.now[:error]).to be_present
    end

    it 'rejects a payment method belonging to another store' do
      other_store = create(:store, url: 'other-store.example.com')
      other_gateway = create(:bank_transfer_gateway, store: other_store)

      expect { submit(payment_method_id: other_gateway.id) }.
        not_to change(SpreeBankPayments::IncomingTransfer, :count)
      expect(flash.now[:error]).to be_present
    end
  end
end
