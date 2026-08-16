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

    # Registers Spree::BankPayments::Adjuster::Discount in
    # `Rails.application.config.spree.adjusters`.
    #
    # Being in that array at all is what matters: AdjustmentsUpdater runs every
    # registered non-tax adjuster and persists the resulting totals onto the
    # adjustable BEFORE computing tax, so an unregistered adjuster means the
    # line-item discounts never reach taxable_adjustment_total and tax is still
    # computed on the undiscounted price.
    #
    # Position within the array is NOT significant. AdjustmentsUpdater picks the
    # tax adjuster out by name (`adjusters - [tax_adjuster]`) and always runs it
    # last, whatever the order. We insert ahead of it so the array reads in
    # execution order, but appending would behave identically -- do not treat
    # the insertion point as load-bearing.
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

      # Cosmetic: keeps the array in execution order. AdjustmentsUpdater runs
      # the tax adjuster last regardless, so `<<` would be equivalent.
      tax_index = adjusters.index { |adjuster| adjuster.name == 'Spree::Adjustable::Adjuster::Tax' }
      if tax_index
        adjusters.insert(tax_index, Spree::BankPayments::Adjuster::Discount)
      else
        adjusters << Spree::BankPayments::Adjuster::Discount
      end
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
