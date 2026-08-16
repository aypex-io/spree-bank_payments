module Spree
  module BankPayments
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

        allocation.each do |line_item, amount|
          next if amount.zero?

          Spree::Adjustment.create!(
            adjustable: line_item,
            order: order,
            source: payment_method,
            amount: amount,
            label: label,
            eligible: true,
            included: false
          )
        end

        order.update_with_updater!
      end

      private

      attr_reader :order, :payment_method

      def bank_transfer?
        payment_method.is_a?(Spree::BankPayments::Gateway)
      end

      def percent
        return 0.to_d unless bank_transfer?

        payment_method.preferred_discount_percent.to_d
      end

      # Base is item_total, never order.total: order.total is gross and would
      # also discount shipping.
      #
      # This is the authoritative figure. The per-line allocation below must
      # sum to exactly this, to the cent.
      def discount_amount
        -(order.item_total * percent / 100).round(2)
      end

      # The discount is spread across LINE ITEMS rather than sitting on the
      # order, so that it reaches Spree::LineItem#taxable_adjustment_total and
      # actually reduces recorded tax on a tax-inclusive (VAT) store. An
      # order-level adjustment never reaches that sum, which is why the
      # pre-5.1 behaviour left the order recording VAT on the undiscounted
      # price while the customer paid less.
      #
      # Largest-remainder allocation, NOT naive per-line rounding. Rounding
      # each line independently drifts: 3 items at 33.33 with 2.5% gives
      # 0.83 x 3 = 2.49 against an intended 2.50. That cent matters far more
      # than it looks -- order.total must equal the amount quoted on the
      # payment session, and auto-apply requires exact amount equality, so a
      # single cent of drift diverts every payment into the manual admin
      # queue.
      #
      # @return [Array<Array(Spree::LineItem, BigDecimal)>]
      def allocation
        line_items = order.line_items.to_a
        weights = line_items.map { |line_item| line_item.amount.to_d }
        weight_total = weights.sum

        target_cents = (discount_amount.abs * 100).round.to_i
        return [] if target_cents.zero?

        cents =
          if weight_total <= 0
            # Degenerate (all-zero or negative line items): nothing sensible to
            # weight by, so spread evenly and let the remainder rule finish it.
            largest_remainder(Array.new(line_items.size, 1.to_d), line_items.size.to_d, target_cents)
          else
            largest_remainder(weights, weight_total, target_cents)
          end

        line_items.zip(cents.map { |c| -(c.to_d / 100) })
      end

      # Floor every share, then hand the leftover cents out one at a time to
      # the largest fractional remainders (ties broken by original order, so
      # the result is deterministic). Sums to `target_cents` by construction.
      def largest_remainder(weights, weight_total, target_cents)
        exact = weights.map { |weight| target_cents * weight / weight_total }
        floors = exact.map(&:floor)
        leftover = target_cents - floors.sum

        ranked = exact.each_with_index.
                 sort_by { |value, index| [-(value - value.floor), index] }.
                 map(&:last)

        ranked.first(leftover).each { |index| floors[index] += 1 }
        floors
      end

      def label
        Spree.t('bank_payments.discount_label', percent: payment_method.formatted_discount_percent)
      end

      # Type filter covers subclasses (see gateway_type_names): `bank_transfer?`
      # matches them with `is_a?`, so every SQL filter here must too.
      def settled_by_bank_transfer?
        order.payments.completed.joins(:payment_method).
          where(spree_payment_methods: { type: Spree::BankPayments.gateway_type_names }).exists?
      end

      # Scoped by `order.all_adjustments` (every adjustment carrying this
      # order_id, whatever it is adjustable to) rather than `order.adjustments`
      # (order-adjustable only). Since 5.1 the discount lives on line items, so
      # the narrower scope would find nothing and silently orphan the whole
      # discount on a payment-method switch -- the customer keeps a transfer
      # discount while paying by card. The wider scope also still catches the
      # order-level adjustments written by earlier versions of this gem.
      #
      # Matches subclassed gateways too, for the same reason as above.
      def remove_existing
        existing = order.all_adjustments.
                   where(source_type: 'Spree::PaymentMethod',
                         source_id: Spree::BankPayments.gateway_scope.select(:id))

        return if existing.empty?

        existing.destroy_all
        order.update_with_updater!
      end
    end
  end
end
