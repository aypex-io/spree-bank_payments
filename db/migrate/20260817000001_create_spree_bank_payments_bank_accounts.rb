class CreateSpreeBankPaymentsBankAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_bank_payments_bank_accounts do |t|
      t.bigint   :payment_method_id, null: false
      t.string   :provider_account_id
      t.string   :currency, null: false
      t.jsonb    :details, null: false, default: []
      t.boolean  :offered, null: false, default: false
      t.boolean  :active,  null: false, default: true
      t.datetime :synced_at
      t.timestamps
    end

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id active],
              name: 'index_bp_bank_accounts_on_pm_and_active'

    # Sync idempotency. Partial so that hand-created accounts, which have no
    # provider id, are not all collapsed into one NULL row.
    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id provider_account_id],
              unique: true,
              where: 'provider_account_id IS NOT NULL',
              name: 'index_bp_bank_accounts_on_pm_and_provider_id'

    # At most one offered account per currency, guaranteed by the database.
    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id currency],
              unique: true,
              where: 'offered',
              name: 'index_bp_bank_accounts_on_pm_and_currency_offered'
  end
end
