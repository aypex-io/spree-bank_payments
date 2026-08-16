module AypexBankTransfer
  # Called for every payment (see PaymentDecorator), not just bank transfer
  # ones. `remove_existing` always runs first so switching away from bank
  # transfer removes the discount rather than leaving it behind.
  class ApplyDiscount
    def self.call(order:, payment_method:)
      new(order: order, payment_method: payment_method).call
    end

    def initialize(order:, payment_method:)
      @order = order
      @payment_method = payment_method
    end

    def call
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

    # Always item_total. order.total is gross: it rolls in shipping and tax,
    # and on tax-inclusive (VAT) stores it does not account for VAT
    # correctly, so a percentage taken off it both discounts shipping and
    # muddles the VAT position. item_total lets Spree recalculate inclusive
    # tax properly from the discounted base.
    def discount_amount
      -(order.item_total * percent / 100).round(2)
    end

    def label
      Spree.t('bank_transfer.discount_label', percent: percent.to_i)
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
