require 'spec_helper'

RSpec.describe Spree::PaymentSessions::BankTransfer do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it 'stores a normalized copy of the reference on save' do
    session = create(:bank_transfer_payment_session,
                     payment_method: payment_method, external_id: 'TKF-7Q4X2')

    expect(session.external_id_normalized).to eq('TKF7Q4X2')
  end

  it 'includes pending and processing sessions in the open scope' do
    open_session = create(:bank_transfer_payment_session, payment_method: payment_method)
    closed_session = create(:bank_transfer_payment_session, payment_method: payment_method)
    closed_session.complete!

    expect(described_class.open).to include(open_session)
    expect(described_class.open).not_to include(closed_session)
  end

  # Soft-deletion of BankAccount exists precisely so that a session already
  # quoted against it still shows what the customer was told. Without
  # `-> { with_deleted }` on the association, paranoia's default scope makes
  # the account resolve to nil the moment it's soft-deleted, silently
  # blanking the coordinates on an order that is still open.
  it 'still resolves the bank_account association after the account is soft-deleted' do
    account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP')
    session = create(:bank_transfer_payment_session,
                     payment_method: payment_method, bank_account_id: account.id)

    account.destroy

    reloaded = described_class.find(session.id)
    expect(reloaded.bank_account).to be_present
    expect(reloaded.bank_account.detail_sets).to be_present
    expect(reloaded.bank_account.detail_sets.first.fields).not_to be_empty
  end
end
