module AypexBankTransfer
  class Base < ::ActiveRecord::Base
    self.abstract_class = true

    def self.table_name_prefix
      'aypex_bank_transfer_'
    end
  end
end
