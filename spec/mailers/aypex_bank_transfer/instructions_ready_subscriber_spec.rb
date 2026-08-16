require 'spec_helper'

# Events are the primary delivery mechanism for this gem (see task-10 brief):
# the intended first consumer emits Spree webhooks, not ActionMailer sends.
# The shipped InstructionsMailer is only one optional subscriber, wired up in
# config/initializers/spree.rb. This spec proves that wiring actually fires —
# not just that the job/mailer classes work in isolation — by publishing the
# real event and asserting the real subscriber-registered mail gets enqueued.
RSpec.describe 'AypexBankTransfer default mailer event subscription', type: :mailer do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:order_with_line_items, line_items_price: 100.00, shipment_cost: 0) }

  it 'enqueues the instructions mail when bank_transfer.instructions_ready is published and the default mailer is enabled' do
    expect(AypexBankTransfer::Config.disable_default_mailer).to be(false)

    expect do
      payment_method.create_payment_session(order: order)
    end.to have_enqueued_mail(AypexBankTransfer::InstructionsMailer, :instructions)
  end

  it 'enqueues the reminder mail when bank_transfer.reminder_due is published and the default mailer is enabled' do
    session = payment_method.create_payment_session(order: order)

    expect do
      Spree::Events.publish('bank_transfer.reminder_due', session.notification_payload)
    end.to have_enqueued_mail(AypexBankTransfer::InstructionsMailer, :reminder)
  end

  describe 'registry survives a Zeitwerk reload' do
    # Same mechanism, and same regression, as
    # spec/models/aypex_bank_transfer/reconcilers/manual_spec.rb: spree_core's
    # own `to_prepare` hook calls `Spree::Events.reset!` on every reload,
    # which drops Proc-based subscribers. Registering from `after_initialize`
    # (the pre-review version of this gem) meant that reset would run once
    # and never be undone — the default mailer would stop firing for the
    # rest of the process. Registering from `to_prepare` instead (see
    # config/initializers/spree.rb) means AypexBankTransfer.
    # register_default_mailer_subscribers! reruns immediately after that
    # same reset, in the same reload pass, healing it — but only if our
    # `to_prepare` block genuinely runs after spree_core's. This test proves
    # that ordering holds, the same way the reconciler test proves it for
    # Reconcilers::Base's registry.
    it 'still enqueues mail after a simulated reload' do
      Rails.application.reloader.prepare!

      expect do
        payment_method.create_payment_session(order: order)
      end.to have_enqueued_mail(AypexBankTransfer::InstructionsMailer, :instructions)
    end

    it 'does not stack duplicate subscriptions across repeated reloads' do
      3.times { Rails.application.reloader.prepare! }

      # Count subscriptions registered under our *exact* pattern only, not
      # `subscriptions_for` (which also matches wildcard subscribers -- e.g.
      # spree_api's Spree::WebhookEventSubscriber subscribes to '*' and
      # legitimately matches every event, including ours, whenever spree_api
      # is loaded transitively via spree_admin). That wildcard subscriber is
      # registered exactly once by spree_core's own to_prepare, so it would
      # never stack either, but it isn't what this example is about --
      # this example is only about OUR subscribe_once guard.
      exact_pattern_count = lambda do |pattern|
        Spree::Events.registry.all_subscriptions.count { |s| s.pattern == pattern }
      end

      expect(exact_pattern_count.call('bank_transfer.instructions_ready')).to eq(1)
      expect(exact_pattern_count.call('bank_transfer.reminder_due')).to eq(1)

      # A duplicate subscription would enqueue the same mail twice per
      # publish; have_enqueued_mail defaults to asserting exactly once.
      expect do
        payment_method.create_payment_session(order: order)
      end.to have_enqueued_mail(AypexBankTransfer::InstructionsMailer, :instructions).once
    end
  end

  describe 'when the default mailer is disabled' do
    # Unlike the pre-review version of this initializer, disable_default_mailer
    # is no longer read only once at boot: the `unless` guard lives inside
    # `to_prepare` now (see config/initializers/spree.rb), alongside the
    # subscription call it guards, so it is re-evaluated on every reload. A
    # real toggle still requires a reload to take effect (there is no live
    # unsubscribe), but a simulated reload via Rails.application.reloader.
    # prepare! makes the disabled path exercisable in-process, which the
    # pre-review boot-only design could not offer.
    it 'does not (re-)subscribe the default mailer after a reload with the registry cleared' do
      # Spree::Events.reset! is exactly what spree_core's own to_prepare hook
      # calls on every real reload (see lib/aypex_bank_transfer/subscribers.rb)
      # -- invoking it directly here stands in for that, the same way the
      # reconciler regression spec clears its registry directly.
      Spree::Events.reset!

      AypexBankTransfer::Config.disable_default_mailer = true

      begin
        Rails.application.reloader.prepare!

        expect(Spree::Events.registry.registered?('bank_transfer.instructions_ready')).to be(false)

        expect do
          payment_method.create_payment_session(order: order)
        end.not_to have_enqueued_mail(AypexBankTransfer::InstructionsMailer, :instructions)
      ensure
        AypexBankTransfer::Config.disable_default_mailer = false
        Rails.application.reloader.prepare!
      end
    end
  end
end
