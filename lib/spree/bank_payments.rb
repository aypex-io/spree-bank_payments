require 'spree_core'
require 'spree/bank_payments/version'
require 'spree/bank_payments/configuration'
require 'spree/bank_payments/subscribers'
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
