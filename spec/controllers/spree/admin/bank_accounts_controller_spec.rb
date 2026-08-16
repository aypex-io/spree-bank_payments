require 'spec_helper'

RSpec.describe Spree::Admin::BankAccountsController, type: :controller do
  stub_authorization!

  let(:gateway) { create(:bank_transfer_gateway) }

  it 'lists accounts for the payment method' do
    account = create(:bank_payments_bank_account, payment_method: gateway)

    get :index, params: { payment_method_id: gateway.id }

    expect(assigns(:bank_accounts)).to include(account)
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

    it 'leaves accounts untouched and reports the error rather than 500ing on failure' do
      existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1', active: true)

      allow_any_instance_of(Spree::BankPayments::SyncAccounts).
        to receive(:apply!).and_raise(Spree::BankPayments::SyncAccounts::EmptyResponseError, 'provider reported no accounts')

      expect {
        post :sync, params: { payment_method_id: gateway.id }
      }.not_to raise_error

      expect(response).to redirect_to(spree.admin_payment_method_bank_accounts_path(gateway))
      expect(flash[:error]).to include('Sync failed')
      expect(existing.reload).to be_active
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
