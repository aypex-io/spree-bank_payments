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
      end
    end

    private

    def expire_for(payment_method)
      ::Spree::PaymentSessions::BankTransfer.
        open.
        where(payment_method_id: payment_method.id).
        where(expires_at: ...Time.current).
        find_each do |session|
          ActiveRecord::Base.transaction do
            session.expire!
            cancel_order(session.order)
          end

          Spree::Events.publish('bank_transfer.expired', session.notification_payload)
        end
    end

    def cancel_order(order)
      return if order.blank? || order.canceled?

      order.cancel!
    end
  end
end
