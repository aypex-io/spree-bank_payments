module Spree
  module BankPayments
    module Adjusters
      # Writes the bank transfer discount as Spree::Discount rows, one per
      # line item, while bank transfer is the purchase's selected payment, and
      # removes them otherwise. Registered in Spree.adjusters, so it runs on
      # every recalculation of a cart or draft order (a placed order's money
      # is frozen and adjusters no longer run on it).
      #
      # Kind `manual`, because Spree's promotion adjuster deletes every
      # `promotion` row it did not write in the pass and keeps one winner per
      # group: as manual rows the discount survives recalculation and stacks
      # with promotions (20% + 3% is 23%), a concession for paying by
      # transfer rather than a competing offer. Every discount row of a line
      # counts toward its taxable basis, so on a tax-inclusive market the
      # discount lowers the VAT recorded, not just the total.
      #
      # The rows are found by metadata, never by `code`, which is the promotion
      # code snapshot that reports group on.
      class Discount < Spree::Adjusters::Base
        SOURCE = 'spree_bank_payments'.freeze

        def update
          gateway = selected_gateway
          kept = gateway ? write_rows(gateway) : []
          own_rows.where.not(id: kept.map(&:id)).destroy_all
        end

        private

        # The gateway of the purchase's newest open bank transfer session in
        # its own currency, when that gateway gives a discount.
        def selected_gateway
          session = Spree::PaymentSessions::BankTransfer.open.
                    where(id: order.payment_sessions.select(:id), currency: order.currency).
                    order(created_at: :desc, id: :desc).
                    first
          gateway = session&.payment_method
          gateway if gateway&.preferred_discount_percent.to_d.positive?
        end

        def write_rows(gateway)
          lines = order.line_items.to_a.select { |line_item| line_item.amount.positive? }
          return [] if lines.empty?

          percent = gateway.preferred_discount_percent.to_d
          total = Spree::Money::Rounding.to_currency(order.item_total * percent / 100, order.currency)
          return [] unless total.positive?

          shares = Spree::Adjusters::LargestRemainder.apportion(total, lines.map(&:amount), order.currency)

          lines.each_with_index.filter_map do |line_item, index|
            amount = clamp(-shares[index], remaining_base(line_item))
            persist(line_item, gateway, percent, amount) unless amount.zero?
          end
        end

        # A line never goes below zero, whatever else discounts it.
        def clamp(amount, base)
          [amount, -[base, BigDecimal(0)].max].max
        end

        # The line's amount less every discount on it other than this one.
        def remaining_base(line_item)
          others = line_item.discounts.reload.reject { |row| own?(row) }
          line_item.amount + others.sum(&:amount)
        end

        def persist(line_item, gateway, percent, amount)
          row = own_rows.find_or_initialize_by(line_item_id: line_item.id)
          row.assign_attributes(
            owner_attributes.merge(
              kind: 'manual',
              amount: amount,
              label: I18n.t('spree.bank_payments.discount_label', percent: gateway.formatted_discount_percent),
              value: percent,
              value_type: 'percent',
              metadata: { 'source' => SOURCE, 'payment_method_id' => gateway.prefixed_id }
            )
          )
          row.save!
          row
        end

        def own_rows
          order.discounts.manual.where("#{Spree::Discount.table_name}.metadata->>'source' = ?", SOURCE)
        end

        def own?(row)
          row.kind == 'manual' && row.metadata.to_h['source'] == SOURCE
        end

        def owner_attributes
          order.is_a?(Spree::Order) ? { order: order, cart: nil } : { cart: order, order: nil }
        end
      end
    end
  end
end
