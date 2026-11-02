require 'spree_core'
require 'spree/bank_payments/version'
require 'spree/bank_payments/configuration'
require 'spree/bank_payments/subscribers'
require 'spree/bank_payments/events'
require 'spree/bank_payments/engine'

module Spree
  module BankPayments
    # Must live on the *module*, not on Spree::BankPayments::Base.
    #
    # ActiveRecord resolves a table prefix with
    #   (module_parents.detect { |p| p.respond_to?(:table_name_prefix) } || self).table_name_prefix
    # and Spree itself defines `table_name_prefix` as "spree_". Now that these models
    # are nested under Spree, that parent is found first and a class-level method on
    # Base is never consulted -- every table would resolve to spree_<name> instead of
    # spree_bank_payments_<name>. Defining it here puts a closer parent in the chain.
    def self.table_name_prefix
      'spree_bank_payments_'
    end

    # Every STI type name that counts as one of this gem's gateways.
    #
    # `ApplyDiscount#bank_transfer?` tests with `is_a?`, which matches
    # subclasses, so a store subclassing the gateway HAS the discount applied.
    # The SQL filters must agree, or those adjustments would be created but
    # never counted into taxable_adjustment_total (VAT silently unfixed -- the
    # exact bug 5.1.0 fixes) and never removed on a payment-method switch
    # (leaking margin). Resolved at call time so it reflects whatever is loaded.
    def self.gateway_type_names
      ([Spree::BankPayments::Gateway] + Spree::BankPayments::Gateway.descendants).map(&:name).uniq
    end

    # Subquery of payment-method ids for those types. `unscoped` deliberately:
    # a soft-deleted payment method must still have its stale adjustments found
    # and removed.
    def self.gateway_scope
      Spree::PaymentMethod.unscoped.where(type: gateway_type_names)
    end

    def self.pg_trgm_available?
      return @pg_trgm_available if defined?(@pg_trgm_available)

      @pg_trgm_available = ActiveRecord::Base.connection.extension_enabled?('pg_trgm')
    rescue StandardError
      # Deliberately NOT memoized: a transient connection failure must not disable
      # payer-name suggestions for the lifetime of the process.
      false
    end
  end
end
