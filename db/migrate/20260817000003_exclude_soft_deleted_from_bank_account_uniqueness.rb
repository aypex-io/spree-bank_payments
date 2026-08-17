class ExcludeSoftDeletedFromBankAccountUniqueness < ActiveRecord::Migration[8.1]
  # BankAccount became paranoid (deleted_at) after these indexes were
  # written. Both predicates guaranteed something about *live* accounts --
  # "one offered account per currency", "one row per provider_account_id"
  # -- but a soft-deleted row still satisfies the old predicates, so it
  # still blocks a new live row from taking its place. Reachable through
  # the ordinary admin path: Task 9's destroy action soft-deletes, so an
  # admin who deletes an offered account and creates a replacement would
  # hit RecordNotUnique against a row they cannot see.
  #
  # Written as explicit up/down rather than `change`: `remove_index ..., name:`
  # carries no column list, so the recorder cannot invert it and any rollback
  # past this migration raised IrreversibleMigration -- including the one the
  # upgrade spec performs to reconstruct a 5.1.1 database.
  def up
    remove_index :spree_bank_payments_bank_accounts, name: 'index_bp_bank_accounts_on_pm_and_currency_offered'
    remove_index :spree_bank_payments_bank_accounts, name: 'index_bp_bank_accounts_on_pm_and_provider_id'

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id currency],
              unique: true,
              where: 'offered AND deleted_at IS NULL',
              name: 'index_bp_bank_accounts_on_pm_and_currency_offered'

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id provider_account_id],
              unique: true,
              where: 'provider_account_id IS NOT NULL AND deleted_at IS NULL',
              name: 'index_bp_bank_accounts_on_pm_and_provider_id'
  end

  # Restores the predicates exactly as 20260817000001 created them.
  def down
    remove_index :spree_bank_payments_bank_accounts, name: 'index_bp_bank_accounts_on_pm_and_currency_offered'
    remove_index :spree_bank_payments_bank_accounts, name: 'index_bp_bank_accounts_on_pm_and_provider_id'

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id currency],
              unique: true,
              where: 'offered',
              name: 'index_bp_bank_accounts_on_pm_and_currency_offered'

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id provider_account_id],
              unique: true,
              where: 'provider_account_id IS NOT NULL',
              name: 'index_bp_bank_accounts_on_pm_and_provider_id'
  end
end
