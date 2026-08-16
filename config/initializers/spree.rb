Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << SpreeBankPayments::Gateway

  # I4: without this the unmatched-transfers queue (and the "record a
  # received transfer" form that is the only ingress under the default
  # Manual reconciler) is reachable only by typing the URL.
  #
  # `Spree.admin.navigation.sidebar.add` is spree_admin 5.6's supported
  # extension point -- the same call its own scaffold generator emits
  # (lib/generators/spree/admin/scaffold/templates/navigation_initializer.rb.tt)
  # and the same registry its defaults use
  # (config/initializers/spree_admin_navigation.rb), rendered by
  # `render_navigation(:sidebar)`. Checked, not assumed.
  #
  # Guarded because spree_admin is an optional companion: a store running
  # headless (API only, no admin UI) must not blow up at boot.
  if defined?(::Spree::Admin::Engine) && ::Spree.admin.respond_to?(:navigation)
    ::Spree.admin.navigation.sidebar.add(
      :bank_transfers,
      label: 'Bank transfers',
      url: :admin_bank_transfers_path,
      icon: 'building-bank',
      position: 25,
      # Gated on payment management rather than on IncomingTransfer, which
      # Spree's Ability has no rule for -- `can?` would be false for every
      # admin and the entry would never render.
      if: -> { can?(:manage, ::Spree::Payment) },
      active: -> { controller_name == 'bank_transfers' }
    )
  end
end

# Reconciler registration, and the default mailer's event subscriptions,
# live in `to_prepare`, not `after_initialize`, because `Reconcilers::Base`
# autoloads from app/models: Zeitwerk re-creates the class (and its
# @registry class-instance variable) on every code reload in development,
# but `after_initialize` only runs once at boot. `to_prepare` re-runs on
# every reload, so both registries survive. Re-registering is safe: the
# reconciler registry is a plain string-keyed hash, so registering the same
# key twice is a no-op, and SpreeBankPayments.register_default_mailer_subscribers!
# is itself idempotent (see lib/spree_bank_payments/subscribers.rb) — it
# guards each Spree::Events.subscribe call with `registry.registered?` so
# `to_prepare` firing repeatedly cannot stack duplicate subscriptions and
# send duplicate mail.
#
# The payment-method line above stays in `after_initialize`:
# `config.spree.payment_methods` is a plain Array, so running that line on
# every reload would duplicate the entry.
Rails.application.config.to_prepare do
  SpreeBankPayments::Reconcilers::Base.register('manual', SpreeBankPayments::Reconcilers::Manual)

  # Subscribers must re-register per reload too: spree_core's own to_prepare hook
  # calls Spree::Events.reset!, which drops Proc-based subscribers registered at boot.
  SpreeBankPayments.register_default_mailer_subscribers! unless SpreeBankPayments::Config.disable_default_mailer
end
