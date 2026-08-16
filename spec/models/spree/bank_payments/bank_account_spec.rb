require 'spec_helper'

RSpec.describe Spree::BankPayments::BankAccount do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it 'upcases the currency on write' do
    account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'gbp')

    expect(account.reload.currency).to eq('GBP')
  end

  it 'requires at least one detail set with a non-blank field' do
    account = build(:bank_payments_bank_account, payment_method: payment_method, details: [])

    expect(account).not_to be_valid
    expect(account.errors[:details]).to be_present
  end

  it 'rejects a detail set whose fields are all blank' do
    account = build(:bank_payments_bank_account, payment_method: payment_method,
                    details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'Sort code', 'value' => '' }] }])

    expect(account).not_to be_valid
  end

  # The database, not a form validation, is what guarantees "one offered per
  # currency" -- the admin checklist and sync both depend on it being true.
  it 'refuses a second offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The unique index is the real guarantee (see the spec above, which
  # bypasses validation to prove it) -- this validation exists only so the
  # admin who trips it sees a form error rather than an unrescued
  # RecordNotUnique. Task 1 shipped the index with no validation in front
  # of it; Task 9's admin form is what actually makes this reachable.
  it 'reports a validation error, not a database exception, for a second offered account in the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    expect(second).not_to be_valid
    expect(second.errors[:currency]).to be_present
    expect { second.save }.not_to raise_error
    expect(second).not_to be_persisted
  end

  it 'allows a second NON-offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: false)

    expect(second).to be_valid
    expect { second.save! }.not_to raise_error
  end

  it 'refuses a duplicate provider_account_id on the same payment method' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')
    dup = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')

    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows many hand-created accounts with no provider_account_id' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'GBP')
    other = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'EUR')

    expect { other.save! }.not_to raise_error
  end

  # Spree::PaymentMethod is acts_as_paranoid. Gateway#bank_accounts has
  # `dependent: :destroy`, and paranoia's restore_associated_records only
  # restores associations that are BOTH `dependent: :destroy` AND paranoid
  # themselves -- so BankAccount must be paranoid too, or a soft-deleted
  # gateway hard-deletes its accounts with no way back.
  # The partial unique indexes were written when this table had no
  # deleted_at column, i.e. when "destroyed" meant "gone". Now that
  # BankAccount is paranoid, a soft-deleted row still exists and still
  # satisfies `where: 'offered'` / `where: 'provider_account_id IS NOT
  # NULL'` unless the predicate also excludes it -- a live index checking a
  # dead row. Reachable through the ordinary admin path: Task 9's destroy
  # action soft-deletes, so an admin who deletes the GBP account and
  # creates a replacement would hit RecordNotUnique against a row they
  # cannot see.
  describe 'uniqueness ignores soft-deleted rows' do
    it 'allows a new offered account for a currency whose previous offered account was soft-deleted' do
      old = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
      old.destroy

      replacement = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

      expect { replacement.save! }.not_to raise_error
    end

    it 'allows a new account to reuse a provider_account_id that was soft-deleted' do
      old = create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')
      old.destroy

      resynced = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1',
                        currency: 'EUR')

      expect { resynced.save! }.not_to raise_error
    end
  end

  describe 'soft-delete cascade (paranoid parent, paranoid child)' do
    it 'soft-deletes the account, rather than destroying it, when the payment method is soft-deleted' do
      account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

      payment_method.destroy

      expect(Spree::BankPayments::BankAccount.where(id: account.id)).to be_empty
      expect(Spree::BankPayments::BankAccount.with_deleted.find(account.id)).to be_present
      expect(account.reload.deleted_at).to be_present
    end

    # paranoia's restore_associated_records restores only associations that
    # are `dependent: :destroy` AND paranoid, calling
    # `record.restore(recursive: true, ...)` on each -- so `recursive: true`
    # on the gateway is what brings the accounts back, not a default.
    it 'recovers the account when the payment method is restored recursively' do
      account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
      payment_method.destroy

      payment_method.restore(recursive: true)

      expect(account.reload.deleted_at).to be_nil
      expect(Spree::BankPayments::BankAccount.where(id: account.id)).to include(account)
    end

    it 'does NOT recover the account when the payment method is restored non-recursively' do
      account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
      payment_method.destroy

      payment_method.restore

      expect(account.reload.deleted_at).to be_present
    end
  end

  describe '.for_currency' do
    it 'finds an uppercase-stored account from a lowercase lookup' do
      account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP')

      expect(described_class.for_currency('gbp')).to include(account)
    end

    it 'does not match a different currency' do
      create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP')

      expect(described_class.for_currency('EUR')).to be_empty
    end

    # normalize_currency runs on validation, so a write path that skips it
    # leaves a lowercase row behind. The scope must still be the thing that
    # fails loudly rather than the storefront quoting nothing.
    it 'does not silently match a row written without normalisation' do
      account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP')
      account.update_column(:currency, 'gbp')

      expect(described_class.for_currency('gbp')).to be_empty
    end
  end
end
