module Spree
  module BankPayments
    # Takes bank transfer back off a purchase: cancels its open bank transfer
    # sessions, voids the payments they left pending, and recalculates so the
    # discount comes off with them.
    #
    # Called before another payment method is chosen (its amount is computed
    # from the purchase as it stands, so the discount must already be gone)
    # and before a fresh bank transfer session replaces an older one.
    class ReleaseSelection
      UNSETTLED_PAYMENT_STATUSES = %w[checkout pending processing].freeze

      # @param purchase [Spree::Cart, Spree::Order]
      # @param except [Spree::PaymentSession, nil] a session to leave open
      # @return [Boolean] whether anything was released
      def self.call(purchase:, except: nil)
        new(purchase: purchase, except: except).call
      end

      def initialize(purchase:, except: nil)
        @purchase = purchase
        @except = except
      end

      # Under the purchase's lock, and never once Spree has claimed the cart
      # for completion: releasing then could void the payment completion has
      # just counted, placing an order nothing would reconcile.
      def call
        purchase.with_lock do
          next false if claimed_for_completion?

          released = open_sessions.to_a.map { |session| release(session) }.any?
          Spree::BankPayments.recalculate!(purchase) if released
          released
        end
      end

      private

      attr_reader :purchase, :except

      def claimed_for_completion?
        purchase.respond_to?(:completion_claimed?) && purchase.completion_claimed?
      end

      def open_sessions
        scope = Spree::PaymentSessions::BankTransfer.open.where(id: purchase.payment_sessions.select(:id))
        except ? scope.where.not(id: except.id) : scope
      end

      def release(session)
        payment = session.payment
        payment.void! if payment && UNSETTLED_PAYMENT_STATUSES.include?(payment.status)
        session.cancel
      end
    end
  end
end
