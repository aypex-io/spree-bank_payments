module Spree
  module BankPayments
    # Folds the pre-5.2 flat account_* preferences into a BankAccount so an
    # upgrading install keeps quoting exactly what it quoted before.
    #
    # `offered: true` is set here unconditionally -- the one place in the gem
    # where code, not an admin, decides that. Everywhere else (including
    # sync) `offered` is the admin's checklist: they opt an account in once
    # they've verified it. Here there is nothing to verify -- the store was
    # already quoting these exact details before the upgrade, so keeping
    # `offered` false would silently stop offering bank transfer the moment
    # this migration ran. Do not "fix" this to match the sync default.
    class MigrateLegacyAccounts
      LEGACY_FIELDS = [
        ['Account name',   :preferred_account_name],
        ['IBAN',           :preferred_account_iban],
        ['BIC',            :preferred_account_bic],
        ['Sort code',      :preferred_account_sort_code],
        ['Account number', :preferred_account_number]
      ].freeze

      def self.call
        # .with_deleted on both sides: a soft-deleted gateway must still be
        # migrated (restoring it later must not leave it permanently
        # unmigrated, since this runs once), and a soft-deleted BankAccount
        # is an admin's deliberate decision to withdraw the account, not an
        # absence to be silently refilled on the next invocation -- this
        # service is explicitly re-callable outside db:migrate.
        Spree::BankPayments::Gateway.with_deleted.find_each do |gateway|
          next if gateway.bank_accounts.with_deleted.exists?

          fields = LEGACY_FIELDS.filter_map do |label, reader|
            value = gateway.public_send(reader).to_s.strip
            { 'label' => label, 'value' => value } unless value.empty?
          end
          next if fields.empty?

          currency = gateway.store&.default_currency.presence || Spree::Config[:currency]

          gateway.bank_accounts.create!(
            currency: currency.to_s.upcase,
            offered: true,
            active: true,
            details: [{ 'label' => 'Bank transfer', 'schemes' => [], 'fields' => fields }]
          )
        end
      end
    end
  end
end
