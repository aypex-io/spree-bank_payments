class MigrateLegacyAccountPreferences < ActiveRecord::Migration[8.1]
  # Deliberately numbered AFTER the deleted_at column and the soft-delete-aware
  # unique indexes. This is the only migration in the gem that runs application
  # code, so it is the only one whose behaviour depends on the *model's* view of
  # the schema: BankAccount is acts_as_paranoid, so every query it issues --
  # including the offered-per-currency uniqueness validation and
  # `bank_accounts.with_deleted` -- references deleted_at. Run before
  # 20260817000002 adds that column and `rails db:migrate` dies with
  # PG::UndefinedColumn on any store that actually has a legacy gateway to
  # migrate, i.e. every store this migration exists for. Do not renumber.
  def up
    Spree::BankPayments::MigrateLegacyAccounts.call
  end

  def down
    # Irreversible by design: the accounts may have been edited since.
  end
end
