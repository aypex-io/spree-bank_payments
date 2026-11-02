Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << Spree::BankPayments::Gateway

  # Here rather than only in `to_prepare`: spree_core assigns
  # `config.spree.adjusters` in its own after_initialize, which runs before
  # this one and would wipe an earlier registration.
  Spree::BankPayments.register_discount_adjuster!

  # Through Spree.subscribers, never Spree::Events.subscribe: activate!
  # does nothing once the registry holds any subscription, so a block
  # subscribed before Spree activates would leave every one of Spree's own
  # subscribers unregistered. Spree activates this list after every engine's
  # after_initialize and again after each code reload. Names, not classes,
  # so Spree resolves the reloaded constant.
  %w[
    Spree::BankPayments::OrderPlacedSubscriber
    Spree::BankPayments::InstructionsMailerSubscriber
  ].each do |subscriber|
    Spree.subscribers << subscriber unless Spree.subscribers.include?(subscriber)
  end
end

# Registrations that must be repeated after every code reload, because
# Zeitwerk re-creates the classes they hold (and the reconciler registry, a
# class-instance variable). `after_initialize` runs once at boot; `to_prepare`
# runs then and on every reload. Each call here is idempotent.
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
end
