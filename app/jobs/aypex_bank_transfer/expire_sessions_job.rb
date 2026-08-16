module AypexBankTransfer
  class ExpireSessionsJob < ActiveJob::Base
    queue_as :default

    def perform
      AypexBankTransfer::Gateway.find_each do |payment_method|
        unless payment_method.reconciler_healthy?
          # Never cancel while blind: the customer may have paid and we simply
          # cannot see it. Alert and leave everything untouched.
          Spree::Events.publish(
            'bank_transfer.reconciler_unhealthy',
            {
              payment_method_id: payment_method.id,
              reconciler: payment_method.preferred_reconciler,
              last_successful_run_at: payment_method.reconciler_state.last_successful_run_at&.iso8601,
              last_error: payment_method.reconciler_state.last_error
            }
          )
          next
        end

        expire_for(payment_method)
      rescue StandardError => e
        # One payment method's failure (a bad state transition, a reconciler
        # gem gone missing, anything) must not wedge expiry for every other
        # payment method processed after it in this loop.
        Spree::Events.publish(
          'bank_transfer.expiry_failed',
          {
            payment_method_id: payment_method.id,
            error: e.message
          }
        )
        Rails.error.report(e, source: 'aypex_bank_transfer.expire_sessions')
        next
      end
    end

    private

    def expire_for(payment_method)
      ::Spree::PaymentSessions::BankTransfer.
        open.
        where(payment_method_id: payment_method.id).
        where(expires_at: ...Time.current).
        find_each do |session|
          # cancel_order runs first, session.expire! last: Spree's state
          # machine publishes `payment_session.expired` synchronously from
          # inside session.expire!, so it must be the final statement in the
          # transaction — if cancel_order were to raise after it, the DB
          # rollback couldn't unwind an event a subscriber may have already
          # acted on. Same ordering rationale as ApplyTransfer (Task 6).
          ActiveRecord::Base.transaction do
            cancel_order(session.order)
            session.expire!
          end

          Spree::Events.publish('bank_transfer.expired', session.notification_payload)
        end
    end

    def cancel_order(order)
      return unless order&.allow_cancel?

      order.cancel!
    end
  end
end
