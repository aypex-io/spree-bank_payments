module SpreeBankPayments
  class Base < ::ActiveRecord::Base
    self.abstract_class = true

    def self.table_name_prefix
      'spree_bank_payments_'
    end
  end
end
