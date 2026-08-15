Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway
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
