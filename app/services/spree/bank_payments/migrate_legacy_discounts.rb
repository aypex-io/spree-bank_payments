module Spree
  module BankPayments
    # Restores 5.x bank transfer discounts after Spree's own upgrade.
    #
    # spree:migrate_adjustments_to_typed_rows does not know an adjustment
    # sourced from a payment method, so it writes each 5.x bank transfer
    # discount as a 0.00 surcharge Fee tagged `legacy_source_type` and
    # `legacy_source_id`. The order's stored total still includes the
    # discount; the next time Spree re-sums it (a cancel, an edit, a refund)
    # the total rises by it. This puts each one back as the manual Discount
    # row the gem writes today, from the amount Spree left in
    # spree_adjustments, and removes the surcharge. Money is not re-summed:
    # the stored totals are already what the buyer was charged.
    #
    # Idempotent: a surcharge it has replaced is gone. A surcharge on a cart
    # is just removed, since the adjuster rewrites a cart's discount.
    class MigrateLegacyDiscounts
      LEGACY_SOURCE_TYPE = 'Spree::PaymentMethod'.freeze

      # @return [Integer] how many surcharges were replaced or removed
      def self.call
        new.call
      end

      def call
        return 0 unless legacy_adjustments.table_exists?

        legacy_fees.find_each.count { |fee| restore(fee) }
      end

      private

      def restore(fee)
        gateway = gateways[fee.metadata['legacy_source_id'].to_i]
        return false if gateway.nil? || fee.line_item_id.nil?

        ActiveRecord::Base.transaction do
          adjustment = legacy_adjustment_for(fee, gateway)
          create_discount(fee, gateway, adjustment) if fee.order_id && adjustment&.amount.to_d.negative?
          fee.destroy!
        end
        true
      end

      def legacy_fees
        Spree::Fee.where("#{Spree::Fee.table_name}.metadata->>'legacy_source_type' = ?", LEGACY_SOURCE_TYPE)
      end

      def gateways
        @gateways ||= Spree::BankPayments::Gateway.with_deleted.index_by(&:id)
      end

      def legacy_adjustment_for(fee, gateway)
        legacy_adjustments.find_by(
          order_id: fee.order_id, source_type: LEGACY_SOURCE_TYPE, source_id: gateway.id,
          adjustable_type: 'Spree::LineItem', adjustable_id: fee.line_item_id
        )
      end

      # The percentage applied in 5.x is not recorded on the adjustment, so
      # the row carries the amount and label only.
      def create_discount(fee, gateway, adjustment)
        Spree::Discount.create!(
          order_id: fee.order_id,
          line_item_id: fee.line_item_id,
          kind: 'manual',
          amount: adjustment.amount,
          label: fee.label,
          metadata: {
            'source' => Spree::BankPayments::Adjusters::Discount::SOURCE,
            'payment_method_id' => gateway.prefixed_id,
            'legacy_adjustment_id' => adjustment.id
          }
        )
      end

      def legacy_adjustments
        @legacy_adjustments ||= Class.new(ActiveRecord::Base) { self.table_name = 'spree_adjustments' }
      end
    end
  end
end
