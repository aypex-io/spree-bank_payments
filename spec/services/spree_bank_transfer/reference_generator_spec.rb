require 'spec_helper'

RSpec.describe SpreeBankTransfer::ReferenceGenerator do
  let(:payment_method) { create(:bank_transfer_gateway) }

  subject(:generator) { described_class.new(payment_method: payment_method) }

  it 'prefixes the configured store prefix' do
    expect(generator.generate).to start_with('TKF-')
  end

  it 'emits six characters from the Crockford alphabet' do
    code = generator.generate.delete_prefix('TKF-')

    expect(code.length).to eq(6)
    expect(code).to match(/\A[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{6}\z/)
  end

  it 'never returns a reference already used by this payment method' do
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'TKF-AAAAAA')
    allow(generator).to receive(:random_code).and_return('AAAAAA', 'ZZZZZZ')

    expect(generator.generate).to eq('TKF-ZZZZZZ')
  end

  it 'raises when it cannot find a free reference' do
    allow(generator).to receive(:random_code).and_return('AAAAAA')
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'TKF-AAAAAA')

    expect { generator.generate }.to raise_error(described_class::ExhaustedError)
  end
end
