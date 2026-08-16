module Spree
  module BankPayments
    module Adjuster
      # Folds this gem's line-item discount adjustments into
      # +taxable_adjustment_total+ so the discount actually reduces recorded
      # tax on a tax-inclusive (VAT) store.
      #
      # Must be registered in `config.spree.adjusters` (see
      # config/initializers/spree.rb): AdjustmentsUpdater runs every registered
      # non-tax adjuster, persists the running totals, and only then runs the
      # tax adjuster -- which recomputes each tax adjustment from
      # LineItem#taxable_basis, itself derived from taxable_amount
      # (= amount + taxable_adjustment_total). Unregistered, the discount never
      # reaches that total and tax stays on the undiscounted price.
      #
      # Position within the adjusters array is not significant: the updater
      # pulls the tax adjuster out by name and always runs it last.
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

        # The type filter covers subclassed gateways. ApplyDiscount decides with
        # `is_a?`, so a store subclassing the gateway would otherwise get
        # adjustments created that this adjuster ignores -- VAT silently
        # unfixed, which is the bug this class exists to prevent.
        def bank_transfer_discount_total
          adjustments.
            eligible.
            where(source_type: 'Spree::PaymentMethod',
                  source_id: Spree::BankPayments.gateway_scope.select(:id)).
            sum(:amount)
        end
      end
    end
  end
end
