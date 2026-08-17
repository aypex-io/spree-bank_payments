class AddPooledToBankAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_bank_payments_bank_accounts, :pooled, :boolean, null: false, default: false
  end
end
