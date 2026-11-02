module BankTransferDiscounts
  # The discount rows the gem owns on a cart or order.
  def bank_transfer_discounts(purchase)
    purchase.discounts.reload.where("metadata->>'source' = ?", 'spree_bank_payments')
  end
end

RSpec.configure do |config|
  config.include BankTransferDiscounts
end
