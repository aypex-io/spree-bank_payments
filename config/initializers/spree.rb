Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway

  # Spree::Events needs no up-front event registration — publishing a name is
  # enough, and subscribers match on string patterns (wildcards supported).
  # This block lives in `after_initialize`, which runs once at boot, so these
  # `subscribe` calls happen exactly once per process — they would double up
  # if moved into `to_prepare`, which reruns on every code reload.
  unless AypexBankTransfer::Config.disable_default_mailer
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

# Reconciler registration lives in `to_prepare`, not `after_initialize`, because
# `Reconcilers::Base` autoloads from app/models: Zeitwerk re-creates the class
# (and its @registry class-instance variable) on every code reload in
# development, but `after_initialize` only runs once at boot. `to_prepare`
# re-runs on every reload, so the registry survives. Re-registering is safe —
# the registry is a plain string-keyed hash, so this is idempotent. The
# payment-method line above stays in `after_initialize`: `config.spree.payment_methods`
# is a plain Array, so running that line on every reload would duplicate the entry.
Rails.application.config.to_prepare do
  AypexBankTransfer::Reconcilers::Base.register('manual', AypexBankTransfer::Reconcilers::Manual)
end
