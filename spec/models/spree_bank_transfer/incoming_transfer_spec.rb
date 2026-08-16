require 'spec_helper'

RSpec.describe SpreeBankTransfer::IncomingTransfer do
  describe '.normalize_reference' do
    it 'upcases, strips non-alphanumerics, and folds Crockford ambiguities' do
      expect(described_class.normalize_reference('tkf-7q4x2')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference(' TKF 7Q4X2 ')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference('TKF/7Q4X2')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference('TKFO7I4L2')).to eq('TKF071412')
    end

    it 'returns an empty string for nil' do
      expect(described_class.normalize_reference(nil)).to eq('')
    end
  end

  describe 'uniqueness' do
    it 'rejects a duplicate provider transaction id' do
      create(:bank_transfer_incoming_transfer, provider: 'test', provider_transaction_id: 'TX1')
      duplicate = build(:bank_transfer_incoming_transfer, provider: 'test', provider_transaction_id: 'TX1')

      expect(duplicate).not_to be_valid
    end
  end
end
