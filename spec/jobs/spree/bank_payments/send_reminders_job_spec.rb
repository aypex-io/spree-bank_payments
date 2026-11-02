require 'spec_helper'

RSpec.describe Spree::BankPayments::SendRemindersJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  before { capture_published_events }

  def session_expiring_in(duration, **attributes)
    create(:bank_transfer_payment_session,
           { order: order, payment_method: payment_method, expires_at: duration.from_now }.merge(attributes))
  end

  it 'publishes a reminder for a session expiring within two days' do
    session = session_expiring_in(36.hours)

    described_class.perform_now

    expect(published('bank_transfer.reminder_due').map { |payload| payload['payment_session_id'] }).
      to eq([session.prefixed_id])
  end

  it 'does not publish for a session expiring far in the future' do
    session_expiring_in(10.days)

    described_class.perform_now

    expect(published('bank_transfer.reminder_due')).to be_empty
  end

  it 'does not publish twice for the same session on the same day' do
    session_expiring_in(36.hours).update!(external_data: { 'last_reminder_on' => Date.current.to_s })

    described_class.perform_now

    expect(published('bank_transfer.reminder_due')).to be_empty
  end

  # Nobody was sent instructions for a checkout that was never placed.
  it 'does not remind a cart that was never placed' do
    session_expiring_in(36.hours, order: nil)

    described_class.perform_now

    expect(published('bank_transfer.reminder_due')).to be_empty
  end
end
