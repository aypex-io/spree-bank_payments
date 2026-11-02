module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # GET /api/v3/admin/bank_payments/payment_methods
          #
          # The store's bank transfer payment methods, which recording a
          # transfer picks from. Under the bank transfers permission rather
          # than Spree's own payment methods endpoint, which needs the store's
          # settings: a role that may record transfers can always pick one.
          class PaymentMethodsController < ResourceController
            def index
              authorize!(:read, Spree::BankPayments::IncomingTransfer)
              methods = Spree::BankPayments::Gateway.where(store_id: current_store.id).order(:position, :id)

              render json: {
                data: methods.map { |method| { id: method.prefixed_id, name: method.name, active: method.active } }
              }
            end

            protected

            def model_class
              Spree::BankPayments::Gateway
            end
          end
        end
      end
    end
  end
end
