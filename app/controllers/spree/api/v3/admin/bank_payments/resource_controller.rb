module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # Base for the gem's Admin API endpoints, under
          # /api/v3/admin/bank_payments. Staff roles reach them through the
          # bank_payments permission scope: reads need read_bank_payments,
          # anything that changes something needs write_bank_payments.
          class ResourceController < Spree::Api::V3::Admin::ResourceController
            scoped_resource :bank_payments

            protected

            # Transfers and bank accounts reach their store through their
            # payment method; Spree's for_store would return none for them.
            def store_scope
              model_class.where(payment_method_id: store_payment_method_ids)
            end

            def store_payment_method_ids
              current_store.payment_methods.select(:id)
            end

            # The store's bank transfer payment method named in the path, or
            # a 404 for another store's.
            def find_payment_method!(id)
              Spree::BankPayments::Gateway.where(store_id: current_store.id).find_by_prefix_id!(id)
            end
          end
        end
      end
    end
  end
end
