Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway
end
