module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # GET /api/v3/admin/bank_payments/orders/:id
          #
          # An order's bank transfer, for the order page: its sessions as the
          # buyer was quoted them, and the transfers applied to them. Empty
          # lists mean the order was not paid by bank transfer.
          class OrdersController < ResourceController
            def show
              authorize!(:read, Spree::BankPayments::IncomingTransfer)
              sessions = Spree::PaymentSessions::BankTransfer.where(order: @resource).order(:created_at, :id).to_a
              transfers = Spree::BankPayments::IncomingTransfer.where(payment_session_id: sessions.map(&:id)).
                          includes(:bank_account, payment_session: :order).order(:occurred_at)

              render json: {
                sessions: PaymentSessionSerializer.new(sessions, params: serializer_params).to_h,
                transfers: IncomingTransferSerializer.new(transfers, params: serializer_params).to_h
              }
            end

            protected

            def model_class
              Spree::Order
            end

            def store_scope
              current_store.orders
            end

            # The order is the subject here, not a bank payments record, so
            # no CanCanCan scope narrows it; reading needs read_bank_payments.
            def scope
              store_scope
            end
          end
        end
      end
    end
  end
end
