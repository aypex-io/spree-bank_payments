module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # GET /api/v3/admin/bank_payments/payment_methods/:payment_method_id/health
          #
          # What the payment method's setup guide shows: the reconciler's
          # health and last poll, the webhook URL to paste into the provider,
          # and which currencies an account is offered in (none means bank
          # transfer is offered nowhere).
          class HealthController < ResourceController
            def show
              authorize!(:read, Spree::BankPayments::IncomingTransfer)
              state = @payment_method.reconciler_state

              render json: {
                health: @payment_method.health.to_s,
                reconciler: @payment_method.preferred_reconciler.to_s,
                last_successful_run_at: state.last_successful_run_at&.iso8601,
                last_error: state.last_error,
                consecutive_failures: state.consecutive_failures,
                webhook_url: @payment_method.webhook_url,
                offered_currencies: @payment_method.bank_accounts.active.offered.order(:currency).pluck(:currency)
              }
            end

            protected

            def model_class
              Spree::BankPayments::Gateway
            end

            def set_parent
              @payment_method = find_payment_method!(params[:payment_method_id])
            end

            def set_resource; end
          end
        end
      end
    end
  end
end
