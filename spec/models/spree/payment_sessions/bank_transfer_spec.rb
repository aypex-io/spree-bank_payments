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
end
