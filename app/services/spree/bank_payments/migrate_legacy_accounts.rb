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
        Spree::BankPayments::Gateway.find_each do |gateway|
          next if gateway.bank_accounts.exists?

          fields = LEGACY_FIELDS.filter_map do |label, reader|
            value = gateway.public_send(reader).to_s.strip
            { 'label' => label, 'value' => value } unless value.empty?
          end
          next if fields.empty?

          gateway.bank_accounts.create!(
            currency: Spree::Config[:currency].to_s.upcase,
            offered: true,
            active: true,
            details: [{ 'label' => 'Bank transfer', 'schemes' => [], 'fields' => fields }]
          )
        end
      end
    end
  end
end
