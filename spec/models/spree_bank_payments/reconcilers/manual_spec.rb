require 'spec_helper'
require 'spree_bank_payments/testing_support/reconciler_shared_examples'

RSpec.describe SpreeBankPayments::Reconcilers::Manual do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'

  it 'is always healthy because it never polls' do
    expect(described_class.new(payment_method: payment_method)).to be_healthy
  end

  it 'returns no transfers when polled' do
    expect(described_class.new(payment_method: payment_method).poll(since: 1.day.ago)).to eq([])
  end

  describe 'registry survives a Zeitwerk reload' do
    # The registration lives in `config.to_prepare` (see
    # config/initializers/spree.rb) specifically because `Reconcilers::Base`
    # autoloads and Zeitwerk recreates the class -- and its @registry -- on
    # every reload in development. `Rails.application.reloader.prepare!`
    # re-runs every `to_prepare` block, which is the real mechanism that
    # protects us; this test clears the registry (standing in for what a
    # Zeitwerk unload does to a fresh class's class-instance variable) and
    # then invokes that mechanism directly.
    #
    # NOTE: this does not exercise an *actual* Zeitwerk const reload -- the
    # dummy app's test environment runs with `cache_classes = true`, so Rails
    # never unloads/reloads constants there (that only happens with
    # `enable_reloading`/`cache_classes = false`, which is a dev-only
    # posture). What this test genuinely proves is that the `to_prepare`
    # hook re-registers 'manual' whenever it fires, which is the guarantee
    # the fix actually depends on.
    after { Rails.application.reloader.prepare! }

    it 're-registers manual when to_prepare re-runs after the registry is cleared' do
      expect(SpreeBankPayments::Reconcilers::Base.registry).to include('manual')

      SpreeBankPayments::Reconcilers::Base.registry.clear
      expect(SpreeBankPayments::Reconcilers::Base.registry).to eq({})

      Rails.application.reloader.prepare!

      expect(SpreeBankPayments::Reconcilers::Base.build(payment_method: payment_method))
        .to be_a(described_class)
    end
  end
end
