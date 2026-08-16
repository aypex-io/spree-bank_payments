module Spree
  module BankPayments
    class Base < ::ActiveRecord::Base
      self.abstract_class = true

      # table_name_prefix is deliberately NOT defined here: ActiveRecord prefers a
      # module_parents match over a class-level method, and Spree's own "spree_"
      # prefix would win. It lives on the Spree::BankPayments module instead --
      # see lib/spree/bank_payments.rb.
    end
  end
end
