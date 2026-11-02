require 'spree_core'
require 'spree/bank_payments/version'
require 'spree/bank_payments/configuration'
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

    ADJUSTER_NAME = 'Spree::BankPayments::Adjusters::Discount'.freeze

    # Adds the discount adjuster to Spree.adjusters, exactly once.
    #
    # Called from both hooks in config/initializers/spree.rb: from
    # `after_initialize`, because spree_core *assigns* the array in its own
    # after_initialize and would wipe anything registered earlier, and from
    # `to_prepare`, because the class autoloads from app/models and a code
    # reload leaves the array holding the stale constant. Matching by name
    # swaps the fresh class in. Before core has seeded the array it does
    # nothing; the after_initialize call registers for real.
    #
    # @return [void]
    def self.register_discount_adjuster!
      adjusters = Rails.application.config.spree.adjusters
      return if adjusters.blank?

      adjusters.reject! { |adjuster| adjuster.name == ADJUSTER_NAME }
      adjusters << ADJUSTER_NAME.constantize
    end

    # Recalculates a purchase's totals, which re-runs the adjusters and so
    # writes or removes the bank transfer discount. Spree recalculates on item
    # and address changes, never on a payment method being chosen.
    #
    # @param purchase [Spree::Cart, Spree::Order]
    # @return [void]
    def self.recalculate!(purchase)
      purchase.recalculate_totals!
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
