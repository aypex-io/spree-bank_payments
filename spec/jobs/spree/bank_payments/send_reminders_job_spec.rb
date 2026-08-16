require 'spec_helper'

RSpec.describe Spree::BankPayments::SendRemindersJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  it 'publishes a reminder for a session expiring within two days' do
    session = create(:bank_transfer_payment_session,
                     order: order, payment_method: payment_method, expires_at: 36.hours.from_now)

    expect(Spree::Events).to receive(:publish).with(
      'bank_transfer.reminder_due', hash_including(payment_session_id: session.id)
    )

    described_class.perform_now
  end

  it 'does not publish for a session expiring far in the future' do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, expires_at: 10.days.from_now)

    expect(Spree::Events).not_to receive(:publish)

    described_class.perform_now
  end

  it 'does not publish twice for the same session on the same day' do
    session = create(:bank_transfer_payment_session,
                     order: order, payment_method: payment_method, expires_at: 36.hours.from_now)
    session.update!(external_data: { 'last_reminder_on' => Date.current.to_s })

    expect(Spree::Events).not_to receive(:publish)

    described_class.perform_now
  end
end
