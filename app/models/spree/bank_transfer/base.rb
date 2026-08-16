module Spree
  module BankTransfer
    class Base < ::ActiveRecord::Base
      self.abstract_class = true

      # table_name_prefix is deliberately NOT defined here: ActiveRecord prefers a
      # module_parents match over a class-level method, and Spree's own "spree_"
      # prefix would win. It lives on the Spree::BankTransfer module instead --
      # see lib/spree/bank_transfer.rb.
    end
  end
end
