Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << Spree::BankPayments::Gateway

  # Here rather than only in `to_prepare`: spree_core assigns
  # `config.spree.adjusters` in its own after_initialize, which runs before
  # this one and would wipe an earlier registration.
  Spree::BankPayments.register_discount_adjuster!
end

# Reconciler registration, and the default mailer's event subscriptions,
# live in `to_prepare`, not `after_initialize`, because `Reconcilers::Base`
# autoloads from app/models: Zeitwerk re-creates the class (and its
# @registry class-instance variable) on every code reload in development,
# but `after_initialize` only runs once at boot. `to_prepare` re-runs on
# every reload, so both registries survive. Re-registering is safe: the
# reconciler registry is a plain string-keyed hash, so registering the same
# key twice is a no-op, and Spree::BankPayments.register_default_mailer_subscribers!
# is itself idempotent (see lib/spree/bank_payments/subscribers.rb) — it
# guards each Spree::Events.subscribe call with `registry.registered?` so
# `to_prepare` firing repeatedly cannot stack duplicate subscriptions and
# send duplicate mail.
#
# The payment-method line above stays in `after_initialize`:
# `config.spree.payment_methods` is a plain Array, so running that line on
# every reload would duplicate the entry.
Rails.application.config.to_prepare do
  Spree::BankPayments::Reconcilers::Base.register('manual', Spree::BankPayments::Reconcilers::Manual)

  Spree::BankPayments.declare_events!

  # Releases bank transfer before the Store API sizes another method's
  # session or payment. Re-checked per reload: both the controllers and the
  # module autoload.
  [
    Spree::Api::V3::Store::Carts::PaymentSessionsController,
    Spree::Api::V3::Store::Carts::PaymentsController
  ].each do |controller|
    next if controller.ancestors.include?(Spree::BankPayments::ReleaseOnOtherMethod)

    controller.prepend(Spree::BankPayments::ReleaseOnOtherMethod)
  end

  # Swaps in the freshly autoloaded adjuster after a code reload. A no-op on
  # first boot, before core has seeded the array.
  Spree::BankPayments.register_discount_adjuster!

  # Subscribers must re-register per reload too: spree_core's own to_prepare hook
  # calls Spree::Events.reset!, which drops Proc-based subscribers registered at boot.
  Spree::BankPayments.register_default_mailer_subscribers! unless Spree::BankPayments::Config.disable_default_mailer
end
