require 'spec_helper'

RSpec.describe Spree::BankPayments::HealthReporter do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:logger) { instance_spy(ActiveSupport::Logger) }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def report(status, reason)
    described_class.call(payment_method: payment_method, status: status, reason: reason)
  end

  it 'logs a transition into an unhealthy state at WARN' do
    expect(report(:transient, :provider_error)).to be(true)
    expect(logger).to have_received(:warn).with(/event=bank_transfer\.reconciler_health\.unhealthy/)
  end

  it 'logs a revoked consent at ERROR, because it needs a human not a retry' do
    report(:consent_revoked, :consent_revoked)

    expect(logger).to have_received(:error).with(/reason=consent_revoked/)
  end

  # A five-minute poll against a dead consent would otherwise write ~288
  # identical lines a day and bury the recovery line.
  it 'does not re-log an unchanged status within the hour' do
    report(:transient, :provider_error)
    expect(report(:transient, :provider_error)).to be(false)
  end

  it 're-logs once the hour has elapsed, so a window-based alert still fires' do
    report(:transient, :provider_error)
    payment_method.reconciler_state.update!(health_reported_at: 2.hours.ago)

    expect(report(:transient, :provider_error)).to be(true)
  end

  it 'logs recovery at INFO and publishes a recovered event' do
    report(:transient, :provider_error)
    allow(Spree::Events).to receive(:publish)

    expect(report(:ok, :ok)).to be(true)
    expect(logger).to have_received(:info).with(/event=bank_transfer\.reconciler_health\.recovered/)
    expect(Spree::Events).to have_received(:publish).with('bank_transfer.reconciler_health.recovered', hash_including(payment_method_id: payment_method.id))
  end

  it 'stays silent while healthy' do
    expect(report(:ok, :ok)).to be(false)
    expect(report(:ok, :ok)).to be(false)
  end

  # The whole point of the enum. An exception message can carry a bearer token,
  # a signed URL, or a customer's name straight into Loki.
  it 'refuses a reason outside the published enum' do
    report(:transient, 'Bearer oa_prod_hunter2 rejected by upstream')

    expect(logger).to have_received(:warn).with(/reason=unknown/)
    expect(logger).not_to have_received(:warn).with(/hunter2/)
  end
end
