module Spree
  module BankPayments
    class Base < ::ActiveRecord::Base
      self.abstract_class = true

      # The two Spree::Base concerns Spree's Admin API needs from a resource:
      # prefixed ids (`find_by_prefix_id!`, the `id` every API response
      # carries) and the ransack allowlist its `q[...]` filters read. Not
      # Spree::Base itself, which would also bring preferences, lifecycle
      # events and store-uniqueness rules these tables were never built for.
      include ::Spree::PrefixedId
      include ::Spree::RansackableAttributes

      # table_name_prefix is deliberately NOT defined here: ActiveRecord prefers a
      # module_parents match over a class-level method, and Spree's own "spree_"
      # prefix would win. It lives on the Spree::BankPayments module instead --
      # see lib/spree/bank_payments.rb.
    end
  end
end
