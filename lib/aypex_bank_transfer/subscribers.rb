module AypexBankTransfer
  # Registers the default mailer's Spree::Events subscriptions.
  #
  # Extracted out of config/initializers/spree.rb so the same registration
  # code can be invoked defensively from specs. spree_core's own Engine runs
  # `Spree::Events.reset!` + `Spree::Events.activate!` from a `to_prepare`
  # hook on every code reload; `activate!` only re-registers subscribers
  # listed in `Spree.subscribers` (class-based), so it silently drops these
  # Proc-based subscriptions the first time a reload happens after boot.
  # That's a known, separately-tracked gap (not fixed here) — production
  # still calls this exactly once, from `after_initialize`. Tests that
  # publish an event and assert the default mailer reacts call this again
  # first if the registry has already lost the subscription, so example
  # order/prior reloads in the suite can't produce a false negative.
  def self.register_default_mailer_subscribers!
    Spree::Events.subscribe('bank_transfer.instructions_ready') do |event|
      AypexBankTransfer::InstructionsMailer.
        instructions(event.payload[:payment_session_id]).deliver_later
    end

    Spree::Events.subscribe('bank_transfer.reminder_due') do |event|
      AypexBankTransfer::InstructionsMailer.
        reminder(event.payload[:payment_session_id]).deliver_later
    end
  end
end
