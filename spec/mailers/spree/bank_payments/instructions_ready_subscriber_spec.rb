require 'spec_helper'

# The default mailer is one optional consumer of the customer-facing events;
# stores that email from webhooks turn it off. Registration itself is pinned
# in spec/lib/spree/bank_payments/subscriber_activation_spec.rb.
RSpec.describe Spree::BankPayments::InstructionsMailerSubscriber, type: :mailer do
  let(:gateway) { create(:bank_transfer_gateway) }
  let(:order) { create(:order, email: 'buyer@example.com', currency: 'GBP') }
  let(:session) do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    create(:bank_transfer_payment_session, order: order, payment_method: gateway, currency: 'GBP')
  end

  it 'enqueues the instructions mail when instructions are ready' do
    expect { session.publish_bank_transfer_event('bank_transfer.instructions_ready') }.
      to have_enqueued_mail(Spree::BankPayments::InstructionsMailer, :instructions)
  end

  it 'enqueues the reminder mail when a reminder is due' do
    expect { session.publish_bank_transfer_event('bank_transfer.reminder_due') }.
      to have_enqueued_mail(Spree::BankPayments::InstructionsMailer, :reminder)
  end

  it 'enqueues the expired mail when an unpaid order is cancelled' do
    expect { session.publish_bank_transfer_event('bank_transfer.expired') }.
      to have_enqueued_mail(Spree::BankPayments::InstructionsMailer, :expired)
  end

  context 'when the default mailer is disabled' do
    around do |example|
      Spree::BankPayments::Config.disable_default_mailer = true
      example.run
    ensure
      Spree::BankPayments::Config.disable_default_mailer = false
    end

    it 'sends nothing' do
      expect { session.publish_bank_transfer_event('bank_transfer.instructions_ready') }.
        not_to have_enqueued_mail(Spree::BankPayments::InstructionsMailer, :instructions)
    end

    it 'sends no expired mail' do
      expect { session.publish_bank_transfer_event('bank_transfer.expired') }.
        not_to have_enqueued_mail(Spree::BankPayments::InstructionsMailer, :expired)
    end
  end
end
