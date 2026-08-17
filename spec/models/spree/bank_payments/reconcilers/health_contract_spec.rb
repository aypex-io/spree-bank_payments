require 'spec_helper'

RSpec.describe Spree::BankPayments::Reconcilers::Base do
  let(:payment_method) { create(:bank_transfer_gateway) }

  # A provider gem written against 5.1.1 or 5.2.0 overrides #healthy? and has
  # never heard of #health. It must keep working untouched -- this is the
  # whole backward-compatibility promise of 5.3.0.
  describe 'a legacy reconciler that implements only #healthy?' do
    let(:klass) do
      Class.new(described_class) do
        def healthy? = false
      end
    end

    it 'derives :transient from a false #healthy?' do
      expect(klass.new(payment_method: payment_method).health).to eq(:transient)
    end

    it 'derives :ok from a true #healthy?' do
      healthy = Class.new(described_class) { def healthy? = true }
      expect(healthy.new(payment_method: payment_method).health).to eq(:ok)
    end
  end

  describe 'a 5.3 reconciler that implements only #health' do
    let(:klass) do
      Class.new(described_class) do
        def health = :consent_revoked
      end
    end

    it 'derives #healthy? from #health' do
      expect(klass.new(payment_method: payment_method).healthy?).to be(false)
    end

    it 'reports :ok as healthy' do
      ok = Class.new(described_class) { def health = :ok }
      expect(ok.new(payment_method: payment_method).healthy?).to be(true)
    end
  end

  # Neither overridden is a contract violation. It must say so, not recurse
  # until the stack blows -- the two defaults are defined in terms of each
  # other, so an unguarded pair would SystemStackError.
  describe 'a reconciler that implements neither' do
    let(:klass) { Class.new(described_class) }

    it 'raises NotImplementedError rather than recursing' do
      expect { klass.new(payment_method: payment_method).healthy? }.
        to raise_error(NotImplementedError, /must implement/)
    end
  end
end
