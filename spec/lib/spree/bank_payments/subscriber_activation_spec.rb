require 'spec_helper'

# Spree::Events.activate! does nothing once the registry holds any
# subscription. A gem that subscribes a block from to_prepare, which runs
# before Spree activates Spree.subscribers, therefore leaves every one of
# Spree's own subscribers (webhooks, order statuses, order.placed side
# effects) unregistered. These pin that the gem's subscribers go through
# Spree.subscribers instead, as Spree's own do.
RSpec.describe 'Spree::BankPayments subscriber activation' do
  def subscribers_for(name)
    Spree::Events.registry.subscriptions_for(name).map { |subscription| subscription.subscriber.to_s }
  end

  it "leaves Spree's own subscribers active" do
    expect(subscribers_for('order.placed')).to include('Spree::OrderPlacedSubscriber')
  end

  it 'subscribes the placement subscriber' do
    expect(subscribers_for('order.placed')).to include('Spree::BankPayments::OrderPlacedSubscriber')
  end

  it 'subscribes the default mailer to the instructions' do
    expect(subscribers_for('bank_transfer.instructions_ready')).to include('Spree::BankPayments::InstructionsMailerSubscriber')
  end

  it 'subscribes the default mailer to the reminders' do
    expect(subscribers_for('bank_transfer.reminder_due')).to include('Spree::BankPayments::InstructionsMailerSubscriber')
  end
end
