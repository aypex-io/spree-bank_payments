Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway

  AypexBankTransfer::Reconcilers::Base.register('manual', AypexBankTransfer::Reconcilers::Manual)
end
