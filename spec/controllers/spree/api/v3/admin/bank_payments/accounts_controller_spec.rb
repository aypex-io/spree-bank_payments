require 'spec_helper'

RSpec.describe Spree::Api::V3::Admin::BankPayments::AccountsController, type: :controller do
  render_views

  include_context 'API v3 Admin authenticated'

  let(:gateway) { create(:bank_transfer_gateway, store: store) }
  let(:uk_details) do
    [{ 'label' => 'UK payments', 'fields' => [{ 'label' => 'Sort code', 'value' => '04-00-75' },
                                              { 'label' => 'Account number', 'value' => '12345678' }] }]
  end

  before { request.headers.merge!(headers) }

  def account(**attributes)
    create(:bank_payments_bank_account, { payment_method: gateway, currency: 'GBP', offered: false }.merge(attributes))
  end

  def path_params(extra = {})
    { payment_method_id: gateway.prefixed_id }.merge(extra)
  end

  def report_accounts(*accounts)
    allow_any_instance_of(Spree::BankPayments::Reconcilers::Manual).to receive(:sync_accounts).and_return(accounts)
  end

  def reported(id)
    Spree::BankPayments::AccountData.new(provider_account_id: id, currency: 'GBP', details: uk_details)
  end

  it 'lists the accounts of a payment method' do
    listed = account

    get :index, params: path_params, as: :json

    expect(json_response['data'].map { |row| row['id'] }).to eq([listed.prefixed_id])
  end

  it "answers 404 for another store's payment method" do
    other = create(:bank_transfer_gateway, store: create(:store))

    get :index, params: { payment_method_id: other.prefixed_id }, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'creates a manual account' do
    post :create, params: path_params(currency: 'EUR', details: uk_details), as: :json

    expect(gateway.bank_accounts.for_currency('EUR').count).to eq(1)
  end

  it 'offers an account' do
    offered = account

    patch :update, params: path_params(id: offered.prefixed_id, offered: true), as: :json

    expect(offered.reload).to be_offered
  end

  it 'withdraws the other offered account in its currency' do
    previous = account(offered: true)
    replacement = account

    patch :update, params: path_params(id: replacement.prefixed_id, offered: true), as: :json

    expect(previous.reload).not_to be_offered
  end

  # The dashboard's edit dialog sends every detail set, all of their parts.
  it "replaces a manual account's detail sets" do
    manual = account
    details = uk_details + [{ 'label' => 'International', 'schemes' => %w[swift],
                              'beneficiary_name' => 'Example Store Ltd',
                              'beneficiary_address' => "1 Example Street\nLondon",
                              'fields' => [{ 'label' => 'IBAN', 'value' => 'GB00EXMP00000000000000' }] }]

    patch :update, params: path_params(id: manual.prefixed_id, details: details), as: :json

    expect(manual.reload.details).to eq(details)
  end

  it "refuses to edit a synced account's details" do
    synced = account(provider_account_id: 'acc-1')

    patch :update, params: path_params(id: synced.prefixed_id, details: uk_details), as: :json

    expect(json_response.dig('error', 'code')).to eq('synced_account')
  end

  it 'deactivates a synced account' do
    synced = account(provider_account_id: 'acc-1')

    patch :update, params: path_params(id: synced.prefixed_id, active: false), as: :json

    expect(synced.reload).not_to be_active
  end

  it 'soft-deletes a manual account' do
    manual = account

    delete :destroy, params: path_params(id: manual.prefixed_id), as: :json

    expect(Spree::BankPayments::BankAccount.with_deleted.find(manual.id).deleted_at).to be_present
  end

  it 'refuses to delete a synced account' do
    synced = account(provider_account_id: 'acc-1')

    delete :destroy, params: path_params(id: synced.prefixed_id), as: :json

    expect(json_response.dig('error', 'code')).to eq('synced_account')
  end

  it 'previews a sync' do
    report_accounts(reported('acc-new'))

    get :sync_plan, params: path_params, as: :json

    expect(json_response['create'].map { |row| row['provider_account_id'] }).to eq(['acc-new'])
  end

  it 'applies a sync' do
    report_accounts(reported('acc-new'))

    post :sync, params: path_params, as: :json

    expect(gateway.bank_accounts.pluck(:provider_account_id)).to eq(['acc-new'])
  end

  # An authentication failure that reports no accounts must never read as
  # "every account disappeared".
  it 'refuses an empty sync' do
    account(provider_account_id: 'acc-1')
    report_accounts

    post :sync, params: path_params, as: :json

    expect(json_response.dig('error', 'code')).to eq('sync_empty')
  end

  context 'with read_bank_payments only' do
    include_context 'API v3 Admin with custom permissions'

    let(:custom_permissions) { %w[read_bank_payments] }

    it 'may not offer an account' do
      patch :update, params: path_params(id: account.prefixed_id, offered: true), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
