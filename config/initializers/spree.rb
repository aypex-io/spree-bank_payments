Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway
end

# Reconciler registration, and the default mailer's event subscriptions,
# live in `to_prepare`, not `after_initialize`, because `Reconcilers::Base`
# autoloads from app/models: Zeitwerk re-creates the class (and its
# @registry class-instance variable) on every code reload in development,
# but `after_initialize` only runs once at boot. `to_prepare` re-runs on
# every reload, so both registries survive. Re-registering is safe: the
# reconciler registry is a plain string-keyed hash, so registering the same
# key twice is a no-op, and AypexBankTransfer.register_default_mailer_subscribers!
# is itself idempotent (see lib/aypex_bank_transfer/subscribers.rb) — it
# guards each Spree::Events.subscribe call with `registry.registered?` so
# `to_prepare` firing repeatedly cannot stack duplicate subscriptions and
# send duplicate mail.
#
# The payment-method line above stays in `after_initialize`:
# `config.spree.payment_methods` is a plain Array, so running that line on
# every reload would duplicate the entry.
Rails.application.config.to_prepare do
  AypexBankTransfer::Reconcilers::Base.register('manual', AypexBankTransfer::Reconcilers::Manual)

  # Subscribers must re-register per reload too: spree_core's own to_prepare hook
  # calls Spree::Events.reset!, which drops Proc-based subscribers registered at boot.
  AypexBankTransfer.register_default_mailer_subscribers! unless AypexBankTransfer::Config.disable_default_mailer
end
