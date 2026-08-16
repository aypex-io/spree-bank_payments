class AddDeletedAtToSpreeBankPaymentsBankAccounts < ActiveRecord::Migration[8.1]
  def change
    # Spree::PaymentMethod (the gateway BankAccount belongs to) is
    # acts_as_paranoid. `dependent: :destroy` on Gateway#bank_accounts would
    # otherwise hard-delete accounts when the gateway is only soft-deleted --
    # an admin restoring the gateway would find every currency's coordinates
    # permanently gone. Follow Spree::PaymentSession's precedent: make the
    # dependent paranoid too, so the cascade is a soft-delete.
    add_column :spree_bank_payments_bank_accounts, :deleted_at, :datetime
    add_index :spree_bank_payments_bank_accounts, :deleted_at
  end
end
