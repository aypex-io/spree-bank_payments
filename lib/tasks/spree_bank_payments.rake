namespace :spree_bank_payments do
  namespace :upgrade do
    desc "Run after Spree's spree:upgrade: restore 5.x bank transfer discounts it wrote as 0.00 surcharges"
    task legacy_discounts: :environment do
      count = Spree::BankPayments::MigrateLegacyDiscounts.call
      puts "Restored #{count} bank transfer discount(s)."
    end
  end
end
