module AypexBankTransfer
  # Called for every payment (see PaymentDecorator), not just bank transfer
  # ones, so switching away from bank transfer removes the discount rather
  # than leaving it behind -- unless money has already arrived via a
  # completed bank-transfer payment, in which case removal is skipped (see
  # `settled_by_bank_transfer?`).
  class ApplyDiscount
    def self.call(order:, payment_method:)
      new(order: order, payment_method: payment_method).call
    end

    def initialize(order:, payment_method:)
      @order = order
      @payment_method = payment_method
    end

    def call
      # If money has already arrived via a completed bank-transfer payment,
      # a later payment on a different method (store credit, an admin-added
      # card payment, etc.) must not strip the discount: that would raise
      # order.total above what was actually collected and flip an
      # already-paid order back to balance_due.
      return if settled_by_bank_transfer? && !bank_transfer?

      remove_existing
      return unless bank_transfer?
      return if percent.zero?

      order.adjustments.create!(
        adjustable: order,
        order: order,
        source: payment_method,
        amount: discount_amount,
        label: label,
        eligible: true,
        included: false
      )

      order.update_with_updater!
    end

    private

    attr_reader :order, :payment_method

    def bank_transfer?
      payment_method.is_a?(AypexBankTransfer::Gateway)
    end

    def percent
      return 0.to_d unless bank_transfer?

      payment_method.preferred_discount_percent.to_d
    end

    # Base is item_total, never order.total: order.total is gross and would
    # also discount shipping.
    #
    # NOTE: this is an ORDER-level adjustment, so it does NOT reduce recorded
    # VAT. included_tax_total is summed from line items and shipments; an
    # order-level adjustment never reaches taxable_adjustment_total. On a
    # tax-inclusive store the customer pays less while the order still
    # records tax on the undiscounted price. Making the discount tax-aware
    # would require line-item adjustments (as Spree promotions use) -- a
    # deliberate open design question, not an oversight.
    def discount_amount
      -(order.item_total * percent / 100).round(2)
    end

    def label
      Spree.t('bank_transfer.discount_label', percent: formatted_percent)
    end

    # Strip a trailing .0 on whole numbers (3 -> "3") but keep fractional
    # precision (2.5 -> "2.5") -- percent.to_i would silently round 2.5% down
    # to "2%" in customer-facing copy.
    def formatted_percent
      percent == percent.to_i ? percent.to_i.to_s : percent.to_s('F')
    end

    def settled_by_bank_transfer?
      order.payments.completed.joins(:payment_method).
        where(spree_payment_methods: { type: 'AypexBankTransfer::Gateway' }).exists?
    end

    def remove_existing
      existing = order.adjustments.where(source_type: 'Spree::PaymentMethod').
                 joins("INNER JOIN spree_payment_methods ON spree_payment_methods.id = spree_adjustments.source_id").
                 where(spree_payment_methods: { type: 'AypexBankTransfer::Gateway' })

      return if existing.empty?

      existing.destroy_all
      order.update_with_updater!
    end
  end
end
