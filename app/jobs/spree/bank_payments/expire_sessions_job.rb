module Spree
  module BankPayments
    # Closes bank transfer sessions whose payment window has passed.
    #
    # | Session belongs to            | Result                                       |
    # |-------------------------------|----------------------------------------------|
    # | a cart, or a draft order      | expired; nobody to tell                      |
    # | a placed order, paid          | canceled; bank_transfer.session_superseded   |
    # | a placed order, unpaid        | order canceled through Spree, session        |
    # |                               | expired, bank_transfer.expired               |
    #
    # Never while the gateway's reconciler is unhealthy: the buyer may have
    # paid and we simply cannot see it.
    class ExpireSessionsJob < ActiveJob::Base
      queue_as :default

      SETTLED_PAYMENT_STATUSES = %w[paid overcharged].freeze
      CANCEL_NOTE = 'Bank transfer not received by the payment deadline.'.freeze

      def perform
        Spree::BankPayments::Gateway.find_each do |payment_method|
          unless payment_method.reconciler_healthy?
            payment_method.publish_operational_event(
              'bank_transfer.reconciler_unhealthy',
              payment_method_id: payment_method.prefixed_id,
              reconciler: payment_method.preferred_reconciler,
              last_successful_run_at: payment_method.reconciler_state.last_successful_run_at&.iso8601,
              last_error: payment_method.reconciler_state.last_error
            )
            next
          end

          expire_for(payment_method)
        rescue StandardError => e
          # One payment method's failure (a bad state transition, a reconciler
          # gem gone missing, anything) must not wedge expiry for every other
          # payment method processed after it in this loop.
          payment_method.publish_operational_event(
            'bank_transfer.expiry_failed',
            payment_method_id: payment_method.prefixed_id,
            error: e.message
          )
          Rails.error.report(e, source: 'spree_bank_payments.expire_sessions')
          next
        end
      end

      private

      def expire_for(payment_method)
        ::Spree::PaymentSessions::BankTransfer.
          open.
          where(payment_method_id: payment_method.id).
          where(expires_at: ...Time.current).
          find_each { |session| close(session) }
      end

      def close(session)
        order = session.order

        if order.nil? || !order.placed?
          # An abandoned checkout. There is no order to cancel and no
          # cancellation to announce.
          session.expire
        elsif SETTLED_PAYMENT_STATUSES.include?(order.payment_status)
          # C2: paid another way. Nothing else closes the session when that
          # happens, and cancelling would restock an order paid in full.
          # `canceled`, not `expired`: in this gem `expired` means "never paid,
          # we cancelled the order".
          supersede(session)
        else
          cancel_unpaid(session, order)
        end
      end

      def supersede(session)
        session.publish_bank_transfer_event('bank_transfer.session_superseded') if session.cancel
      end

      # The session stays open until Spree has actually cancelled the order:
      # a refused cancel (a host's before_cancel hook, say) leaves a transfer
      # free to match, and staff are told.
      def cancel_unpaid(session, order)
        result = Spree.order_cancel_workflow.call(order: order, note: CANCEL_NOTE, notify_customer: false)

        if result.success?
          session.publish_bank_transfer_event('bank_transfer.expired') if session.expire
        else
          session.payment_method.publish_operational_event(
            'bank_transfer.expiry_failed',
            payment_method_id: session.payment_method.prefixed_id,
            payment_session_id: session.prefixed_id,
            order_number: order.number,
            error: result.error.to_s
          )
        end
      end
    end
  end
end
