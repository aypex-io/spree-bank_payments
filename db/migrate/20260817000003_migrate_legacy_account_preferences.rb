class MigrateLegacyAccountPreferences < ActiveRecord::Migration[8.1]
  def up
    Spree::BankPayments::MigrateLegacyAccounts.call
  end

  def down
    # Irreversible by design: the accounts may have been edited since.
  end
end
