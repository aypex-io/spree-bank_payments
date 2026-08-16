require 'spec_helper'

RSpec.describe Spree::Admin::BankAccountsController, type: :controller do
  stub_authorization!

  let(:gateway) { create(:bank_transfer_gateway) }

  it 'lists accounts for the payment method' do
    account = create(:bank_payments_bank_account, payment_method: gateway)

    get :index, params: { payment_method_id: gateway.id }

    expect(assigns(:bank_accounts)).to include(account)
  end

  # A store-wide "nothing is offered" check only fires when EVERY currency
  # has no offered account -- with GBP offered and EUR not, EUR customers
  # silently lose bank transfer and a store-wide warning says nothing.
  context 'rendering the index view' do
    render_views

    it 'warns by name for a currency with accounts but none offered, and stays quiet for one that is covered' do
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR', offered: false)

      # Avoids rendering the full `spree/admin` layout, which pulls in a
      # Tailwind build this dummy app never runs -- see the identical note
      # in bank_transfers_controller_spec.rb.
      request.headers['Turbo-Frame'] = 'bank-accounts'

      get :index, params: { payment_method_id: gateway.id }

      warning = response.body[/<div class="alert alert-warning">.*?<\/div>/m]
      expect(warning).to include('EUR')
      expect(warning).not_to include('GBP')
    end
  end

  it 'offers an account and unoffers the previous one for that currency' do
    old = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true, provider_account_id: 'a')
    new_account = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: false, provider_account_id: 'b')

    put :toggle_offered, params: { payment_method_id: gateway.id, id: new_account.id }

    expect(new_account.reload).to be_offered
    expect(old.reload).not_to be_offered
  end

  it 'creates a hand-entered account' do
    expect {
      post :create, params: {
        payment_method_id: gateway.id,
        bank_account: {
          currency: 'EUR', offered: '1',
          details: [{ label: 'SEPA', fields: [{ label: 'IBAN', value: 'DE00' }] }].to_json
        }
      }
    }.to change(Spree::BankPayments::BankAccount, :count).by(1)
  end

  it 'refuses to edit details on a synced account' do
    synced = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')

    put :update, params: { payment_method_id: gateway.id, id: synced.id,
                           bank_account: { details: [].to_json } }

    expect(synced.reload.details).to be_present
    expect(flash[:error]).to be_present
  end

  # --- Additional coverage beyond the brief ---

  describe 'one offered account per currency' do
    # BankAccount has no uniqueness validation guarding the partial unique
    # index -- only the index itself. Ticking Offered on a second account
    # for a currency that already has one used to reach the DB and 500.
    it 'surfaces a form error, not a 500, instead of relying on the database constraint' do
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

      expect {
        post :create, params: {
          payment_method_id: gateway.id,
          bank_account: {
            currency: 'GBP', offered: '1',
            details: [{ label: 'SEPA', fields: [{ label: 'IBAN', value: 'DE00' }] }].to_json
          }
        }
      }.not_to change(Spree::BankPayments::BankAccount, :count)

      expect(response).to render_template(:new)
      expect(assigns(:bank_account).errors[:currency]).to be_present
    end

    # The database is still the real guarantee -- the validation is only a
    # nicer error message in front of it. Bypass validation the way
    # bank_account_spec.rb's model-level test does, to prove the index
    # itself still backstops it independently of the controller.
    it 'is still enforced by the database if the validation is bypassed' do
      create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
      second = build(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

      expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'malformed details JSON' do
    it 'is rescued into a form error on create, not a 500' do
      expect {
        post :create, params: {
          payment_method_id: gateway.id,
          bank_account: { currency: 'EUR', offered: '0', details: '{not json' }
        }
      }.not_to change(Spree::BankPayments::BankAccount, :count)

      expect(response).to render_template(:new)
      expect(assigns(:bank_account).errors[:details]).to be_present
    end

    it 'is rescued into a form error on update, not a 500, for a manual account' do
      account = create(:bank_payments_bank_account, payment_method: gateway)

      put :update, params: { payment_method_id: gateway.id, id: account.id,
                             bank_account: { details: '{not json' } }

      expect(response).to render_template(:edit)
      expect(assigns(:bank_account).errors[:details]).to be_present
    end

    # The synced guard must fire on the raw, unparsed params -- a malformed
    # payload must not raise JSON::ParserError before the guard even runs.
    it 'still refuses the edit on a synced account before parsing the malformed JSON' do
      synced = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')

      expect {
        put :update, params: { payment_method_id: gateway.id, id: synced.id,
                               bank_account: { details: '{not json' } }
      }.not_to raise_error

      expect(flash[:error]).to be_present
    end
  end

  it 'refuses to change the currency of a synced account, not just its details' do
    synced = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1', currency: 'GBP')

    put :update, params: { payment_method_id: gateway.id, id: synced.id,
                           bank_account: { currency: 'EUR' } }

    expect(synced.reload.currency).to eq('GBP')
    expect(flash[:error]).to be_present
  end

  describe 'toggle_offered with no current holder for that currency' do
    it 'offers the account without erroring' do
      account = create(:bank_payments_bank_account, payment_method: gateway, currency: 'USD', offered: false)

      put :toggle_offered, params: { payment_method_id: gateway.id, id: account.id }

      expect(account.reload).to be_offered
    end

    it 'un-offers an already-offered account (toggle off)' do
      account = create(:bank_payments_bank_account, payment_method: gateway, currency: 'USD', offered: true)

      put :toggle_offered, params: { payment_method_id: gateway.id, id: account.id }

      expect(account.reload).not_to be_offered
    end
  end

  describe 'destroy' do
    it 'soft-deletes a manual account' do
      account = create(:bank_payments_bank_account, payment_method: gateway)

      expect {
        delete :destroy, params: { payment_method_id: gateway.id, id: account.id }
      }.to change { gateway.bank_accounts.count }.by(-1)

      expect(Spree::BankPayments::BankAccount.only_deleted).to include(account)
    end

    it 'refuses to delete a synced account' do
      synced = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')

      delete :destroy, params: { payment_method_id: gateway.id, id: synced.id }

      expect(synced.reload).to be_present
      expect(flash[:error]).to be_present
    end
  end

  describe 'sync' do
    it 'applies a successful sync via the payment method reconciler' do
      sync_double = instance_double(Spree::BankPayments::SyncAccounts)
      allow(Spree::BankPayments::SyncAccounts).to receive(:new).with(payment_method: gateway).and_return(sync_double)
      expect(sync_double).to receive(:apply!).with(no_args)

      post :sync, params: { payment_method_id: gateway.id }

      expect(flash[:success]).to be_present
      expect(response).to redirect_to(spree.admin_payment_method_bank_accounts_path(gateway))
    end

    # Exercises the real guard (via a stubbed reconciler, not a stubbed
    # apply!) so the assertions are actually proving something: an auth
    # failure that comes back as an empty response must not read as "every
    # account disappeared" and must not touch the DB at all.
    it 'leaves accounts untouched and reports the error rather than 500ing on failure' do
      existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1', active: true)
      reconciler = gateway.reconciler
      allow(reconciler).to receive(:sync_accounts).and_return([])
      allow(Spree::BankPayments::Gateway).to receive(:find).and_return(gateway)
      allow(gateway).to receive(:reconciler).and_return(reconciler)

      expect {
        post :sync, params: { payment_method_id: gateway.id }
      }.not_to change { existing.reload.active }

      expect(response).to redirect_to(spree.admin_payment_method_bank_accounts_path(gateway))
      expect(flash[:error]).to include('Sync failed')
      expect(existing.reload).to be_active
    end

    # A bare `rescue StandardError` would also swallow a programming error
    # (e.g. a typo'd method call inside SyncAccounts) and misreport it to
    # the admin as an unremarkable "Sync failed" -- hiding a real bug rather
    # than surfacing it. Only the documented operational failure is caught.
    it 'does not swallow an unexpected error as a sync failure' do
      sync_double = instance_double(Spree::BankPayments::SyncAccounts)
      allow(Spree::BankPayments::SyncAccounts).to receive(:new).and_return(sync_double)
      allow(sync_double).to receive(:apply!).and_raise(NoMethodError, "undefined method 'foo'")

      expect {
        post :sync, params: { payment_method_id: gateway.id }
      }.to raise_error(NoMethodError)
    end

    it 'does not build and hold a plan across the request -- apply! is called with no arguments' do
      sync_double = instance_double(Spree::BankPayments::SyncAccounts)
      allow(Spree::BankPayments::SyncAccounts).to receive(:new).and_return(sync_double)
      expect(sync_double).not_to receive(:plan)
      expect(sync_double).to receive(:apply!).with(no_args)

      post :sync, params: { payment_method_id: gateway.id }
    end
  end
end
