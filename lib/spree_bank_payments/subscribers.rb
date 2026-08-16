module SpreeBankPayments
  # Registers the default mailer's Spree::Events subscriptions.
  #
  # Called from `Rails.application.config.to_prepare`, not `after_initialize`
  # (see config/initializers/spree.rb): spree_core's own Engine runs
  # `Spree::Events.reset!` + `Spree::Events.activate!` from its own
  # `to_prepare` hook on every code reload, and `activate!` only re-registers
  # subscribers listed in `Spree.subscribers` (class-based) — it drops these
  # Proc-based subscriptions. A boot-once `after_initialize` registration
  # would mean the default mailer silently stops working after the first
  # code edit in development, same failure shape as the reconciler registry
  # bug fixed in Task 5. `to_prepare` re-runs on every reload, so calling
  # this again heals it.
  #
  # Must be idempotent: `to_prepare` can fire multiple times without an
  # intervening `Spree::Events.reset!` (e.g. several engines' `to_prepare`
  # blocks running in one reload pass), and Spree::Events::Registry#register
  # has no built-in dedupe — a second `subscribe` call with the same pattern
  # would add a second subscription and send duplicate mail. Guard with
  # `registry.registered?`, which checks for an existing subscription with
  # this exact pattern string.
  def self.register_default_mailer_subscribers!
    subscribe_once('bank_transfer.instructions_ready') do |event|
      SpreeBankPayments::InstructionsMailer.
        instructions(event.payload[:payment_session_id]).deliver_later
    end

    subscribe_once('bank_transfer.reminder_due') do |event|
      SpreeBankPayments::InstructionsMailer.
        reminder(event.payload[:payment_session_id]).deliver_later
    end
  end

  def self.subscribe_once(pattern, &block)
    return if Spree::Events.registry.registered?(pattern)

    Spree::Events.subscribe(pattern, &block)
  end
  private_class_method :subscribe_once
end
