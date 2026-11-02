require 'spec_helper'

RSpec.describe Spree::BankPayments::ReferenceGenerator do
  let(:payment_method) { create(:bank_transfer_gateway) }

  subject(:generator) { described_class.new(payment_method: payment_method) }

  it 'prefixes the configured store prefix' do
    expect(generator.generate).to start_with('ACME-')
  end

  it 'emits six characters from the Crockford alphabet' do
    code = generator.generate.delete_prefix('ACME-')

    expect(code.length).to eq(6)
    expect(code).to match(/\A[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{6}\z/)
  end

  it 'never returns a reference already used by this payment method' do
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'ACME-AAAAAA')
    allow(generator).to receive(:random_code).and_return('AAAAAA', 'ZZZZZZ')

    expect(generator.generate).to eq('ACME-ZZZZZZ')
  end

  it 'raises when it cannot find a free reference' do
    allow(generator).to receive(:random_code).and_return('AAAAAA')
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'ACME-AAAAAA')

    expect { generator.generate }.to raise_error(described_class::ExhaustedError)
  end
end
