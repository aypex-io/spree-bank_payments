require 'spec_helper'

RSpec.describe 'bank account linkage' do
  let(:gateway) { create(:bank_transfer_gateway) }
  let!(:gbp) { create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true, provider_account_id: 'acc-gbp') }
  let(:order) { create(:order_with_line_items, currency: 'GBP') }

  it 'records the quoted account on the session' do
    session = gateway.create_payment_session(order: order)

    expect(session.bank_account).to eq(gbp)
  end

  it 'resolves the arriving account on the transfer' do
    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-1', amount: 10.00, currency: 'GBP',
      reference: 'NOPE', payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer.bank_account).to eq(gbp)
  end

  # Money into the wrong account should be diagnosable, not a mystery currency
  # mismatch.
  it 'queues rather than auto-applying when the accounts disagree' do
    other = create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR',
                   offered: true, provider_account_id: 'acc-eur')
    session = gateway.create_payment_session(order: order)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-2', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: other.provider_account_id
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_unmatched
  end

  it 'still auto-applies when the session has no recorded account' do
    session = gateway.create_payment_session(order: order)
    session.update!(bank_account_id: nil)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-3', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: nil
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_applied
  end

  # Offered and watched are independent: this is what makes switching accounts
  # safe for orders already in flight.
  it 'auto-applies a transfer into a watched but no-longer-offered account' do
    session = gateway.create_payment_session(order: order)
    gbp.update!(offered: false)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-4', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_applied
  end

  # Beyond the brief: a soft-deleted account still had money arrive in it
  # (the provider account itself isn't deleted, only our record of it).
  # #arriving_bank_account only looks at .active, and acts_as_paranoid
  # scopes already exclude soft-deleted rows -- so this falls back to the
  # advisory (no-account) path and still auto-applies on reference + amount
  # + currency. Documented behaviour, not an accident: see the brief's
  # discussion of paranoid BankAccount.
  it 'still auto-applies when the arriving account was soft-deleted' do
    session = gateway.create_payment_session(order: order)
    gbp.destroy

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-5', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_applied
    expect(transfer.bank_account_id).to be_nil
  end

  # Two accounts sharing the same currency but distinguished by
  # provider_account_id: the session must be pinned to the one actually
  # offered when quoted, and a transfer into the OTHER active account of
  # the same currency must still queue rather than guessing.
  it 'queues when two accounts share a currency and the transfer lands in the non-quoted one' do
    gbp.update!(offered: false)
    other_gbp = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP',
                        offered: true, provider_account_id: 'acc-gbp-2')
    session = gateway.create_payment_session(order: order)
    expect(session.bank_account).to eq(other_gbp)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-6', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_unmatched
  end
end
