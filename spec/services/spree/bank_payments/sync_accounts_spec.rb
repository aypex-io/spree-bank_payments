require 'spec_helper'

RSpec.describe Spree::BankPayments::SyncAccounts do
  let(:gateway) { create(:bank_transfer_gateway) }

  def account_data(id, currency = 'GBP')
    Spree::BankPayments::AccountData.new(
      provider_account_id: id, currency: currency,
      details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'Sort code', 'value' => '04-00-75' }] }]
    )
  end

  def stub_sync(values)
    reconciler = gateway.reconciler
    allow(reconciler).to receive(:sync_accounts).and_return(values)
    allow(gateway).to receive(:reconciler).and_return(reconciler)
  end

  it 'creates new accounts, NOT offered' do
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    account = gateway.bank_accounts.sole
    expect(account.provider_account_id).to eq('acc-1')
    expect(account).not_to be_offered
  end

  it 'never changes offered on an existing account' do
    existing = create(:bank_payments_bank_account, payment_method: gateway,
                      provider_account_id: 'acc-1', currency: 'GBP', offered: true)
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    expect(existing.reload).to be_offered
  end

  it 'deactivates an account absent from the response' do
    gone = create(:bank_payments_bank_account, payment_method: gateway,
                  provider_account_id: 'acc-old', currency: 'GBP')
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    expect(gone.reload).not_to be_active
    expect(Spree::BankPayments::BankAccount.where(id: gone.id)).to exist
  end

  # THE guard. An auth failure returning [] must not withdraw bank transfer
  # from the storefront for every currency at once.
  it 'aborts entirely when the provider returns empty but accounts exist' do
    existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    stub_sync([])

    expect { described_class.new(payment_method: gateway).apply! }.
      to raise_error(described_class::EmptyResponseError)
    expect(existing.reload).to be_active
  end

  it 'aborts and writes nothing when the provider raises' do
    existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    reconciler = gateway.reconciler
    allow(reconciler).to receive(:sync_accounts).and_raise(StandardError, 'auth expired')
    allow(gateway).to receive(:reconciler).and_return(reconciler)

    expect { described_class.new(payment_method: gateway).apply! }.to raise_error(StandardError, 'auth expired')
    expect(existing.reload).to be_active
  end

  it 'skips an account with no usable details and reports it' do
    stub_sync([Spree::BankPayments::AccountData.new(provider_account_id: 'acc-2', currency: 'GBP', details: [])])

    plan = described_class.new(payment_method: gateway).plan

    expect(plan[:skipped].map(&:provider_account_id)).to eq(['acc-2'])
    expect { described_class.new(payment_method: gateway).apply! }.
      not_to change(Spree::BankPayments::BankAccount, :count)
  end

  # The consent-callback trigger fires while someone is mid-OAuth-redirect.
  # Additive changes cannot lose anything; a deactivation can withdraw a
  # currency from the storefront, and that must not happen without a human
  # looking at it.
  it 'skips deactivations in additive_only mode' do
    gone = create(:bank_payments_bank_account, payment_method: gateway,
                  provider_account_id: 'acc-old', currency: 'GBP')
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!(additive_only: true)

    expect(gone.reload).to be_active
    expect(gateway.bank_accounts.find_by(provider_account_id: 'acc-1')).to be_present
  end

  it 'never touches bank_account_id on existing sessions' do
    account = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1', offered: true)
    order = create(:order_with_line_items, currency: 'GBP')
    session = gateway.create_payment_session(order: order)
    stub_sync([account_data('acc-1')])

    expect { described_class.new(payment_method: gateway).apply! }.
      not_to change { session.reload.bank_account_id }
  end

  # --- Extra coverage beyond the brief ---

  # Precedent: MigrateLegacyAccounts deliberately does not resurrect a
  # soft-deleted account -- it treats the soft-delete as an admin decision,
  # not an absence. Sync follows the same rule: an admin who deleted an
  # account gets to keep it deleted even if the provider still reports it.
  it 'does not resurrect a soft-deleted account the provider still reports' do
    deleted = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    deleted.destroy
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    expect(Spree::BankPayments::BankAccount.with_deleted.find(deleted.id).deleted_at).to be_present
    expect(gateway.bank_accounts.where(provider_account_id: 'acc-1')).not_to exist
  end

  it 'reports soft-deleted-but-still-reported accounts as skipped, not silently dropped' do
    deleted = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    deleted.destroy
    stub_sync([account_data('acc-1')])

    plan = described_class.new(payment_method: gateway).plan

    expect(plan[:create]).to be_empty
    expect(plan[:skipped].map(&:provider_account_id)).to include('acc-1')
  end

  # A malformed or duplicate provider response must not partially apply --
  # the transaction should roll back entirely rather than leave one of two
  # same-id accounts created.
  it 'rolls back entirely when the provider reports the same id twice' do
    stub_sync([account_data('acc-1'), account_data('acc-1')])

    expect { described_class.new(payment_method: gateway).apply! }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(Spree::BankPayments::BankAccount.count).to eq(0)
  end

  it 'updates currency and details on an existing account without touching offered or active' do
    existing = create(:bank_payments_bank_account, payment_method: gateway,
                      provider_account_id: 'acc-1', currency: 'GBP', offered: true, active: false)
    stub_sync([account_data('acc-1', 'EUR')])

    described_class.new(payment_method: gateway).apply!

    existing.reload
    expect(existing.currency).to eq('EUR')
    expect(existing).to be_offered
    expect(existing).to be_active
  end
end
