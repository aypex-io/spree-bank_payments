module Spree
  module BankPayments
    module Adjuster
      # Folds this gem's line-item discount adjustments into
      # +taxable_adjustment_total+ so the discount actually reduces recorded
      # tax on a tax-inclusive (VAT) store.
      #
      # Registered ahead of Spree::Adjustable::Adjuster::Tax (see
      # config/initializers/spree.rb): AdjustmentsUpdater runs every non-tax
      # adjuster, persists the running totals, and only then runs the tax
      # adjuster -- which recomputes each tax adjustment from
      # LineItem#taxable_basis, itself derived from taxable_amount
      # (= amount + taxable_adjustment_total). Contribute after Tax has run
      # and the tax figure would still be computed on the undiscounted price.
      #
      # Deliberately NOT modelled on the winner-picking half of
      # Spree::Adjustable::Adjuster::Promotion. That adjuster marks every
      # competing promo but the best one `eligible: false`, because only one
      # promotion may apply. A payment-method discount is not competing with
      # promotions -- it is a separate concession for paying by transfer, and
      # must stack (a 20% promo plus a 3% transfer discount is 23% off). So
      # this adjuster only sums; it never touches `eligible`, and this gem's
      # adjustments are excluded from `competing_promos` (which is hardcoded
      # to source_type 'Spree::PromotionAction') so Spree's promo adjuster
      # cannot mark them ineligible either.
      #
      # Nor does it call Adjustment#update! the way the promotion adjuster
      # does: the source here is a Spree::PaymentMethod, which has no
      # `compute_amount`. The amounts are computed once, exactly, by
      # ApplyDiscount and are authoritative.
      class Discount < Spree::Adjustable::Adjuster::Base
        def update
          @totals[:taxable_adjustment_total] += bank_transfer_discount_total
        end

        private

        def bank_transfer_discount_total
          adjustments.
            where(source_type: 'Spree::PaymentMethod').
            eligible.
            joins('INNER JOIN spree_payment_methods ON spree_payment_methods.id = spree_adjustments.source_id').
            where(spree_payment_methods: { type: 'Spree::BankPayments::Gateway' }).
            sum(:amount)
        end
      end
    end
  end
end
