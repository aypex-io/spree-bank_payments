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

    # Inserts Spree::BankPayments::Adjuster::Discount into
    # `Rails.application.config.spree.adjusters`, immediately BEFORE
    # Spree::Adjustable::Adjuster::Tax.
    #
    # Order is load-bearing. Spree::Adjustable::AdjustmentsUpdater runs every
    # non-tax adjuster, persists the resulting totals onto the adjustable, and
    # only then runs the tax adjuster -- which recomputes tax from
    # LineItem#taxable_basis, derived from the taxable_adjustment_total we just
    # contributed. Registered after Tax (or appended blindly) the discount
    # would land too late and tax would still be computed on the undiscounted
    # price.
    #
    # Called from BOTH hooks in config/initializers/spree.rb, for two different
    # reasons:
    #
    # * `after_initialize`, because spree_core *assigns* (not appends to)
    #   `config.spree.adjusters` in its own after_initialize. A `to_prepare`
    #   registration runs earlier in boot (run_prepare_callbacks is a finisher
    #   ahead of finisher_hook) and would be wiped by that assignment.
    # * `to_prepare`, because the adjuster autoloads from app/models: Zeitwerk
    #   re-creates the class on every code reload in development, leaving the
    #   array holding a stale, unloaded constant. Re-running swaps in the
    #   fresh one.
    #
    # Idempotent, and safe to call before spree_core has seeded the array
    # (a no-op then -- the after_initialize call registers for real).
    def self.register_discount_adjuster!
      adjusters = Rails.application.config.spree.adjusters
      return if adjusters.blank?

      # Reject by NAME, not by identity: after a reload the array holds the
      # previous incarnation of the class, which is not `equal?` to the fresh
      # constant, so a `include?` guard would let duplicates accumulate.
      adjusters.reject! { |adjuster| adjuster.name == 'Spree::BankPayments::Adjuster::Discount' }

      tax_index = adjusters.index { |adjuster| adjuster.name == 'Spree::Adjustable::Adjuster::Tax' }
      if tax_index
        adjusters.insert(tax_index, Spree::BankPayments::Adjuster::Discount)
      else
        # No tax adjuster configured: ordering is moot, just contribute.
        adjusters << Spree::BankPayments::Adjuster::Discount
      end
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
