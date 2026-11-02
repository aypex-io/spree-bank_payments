module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # The hand-match queue: observed transfers, newest first, and the
          # open sessions each could belong to.
          class TransfersController < ResourceController
            # Re-declaring the callback replaces ResourceController's, so this
            # lists its actions too.
            before_action :set_resource, only: %i[show update destroy suggestions]

            # GET /api/v3/admin/bank_payments/transfers/:id/suggestions
            #
            # Ranked by SuggestMatches: exact amount and currency first, then
            # payer names that look alike. Fetched per transfer, so the queue
            # never computes them for a whole page at once.
            def suggestions
              matches = Spree::BankPayments::SuggestMatches.new(transfer: @resource).call

              render json: {
                data: SuggestionSerializer.new(matches, params: serializer_params.merge(transfer: @resource)).to_h
              }
            end

            # POST /api/v3/admin/bank_payments/transfers
            #
            # Records a transfer staff saw arrive, and matches it like one a
            # provider delivered: an exact match is applied at once, anything
            # else queues. Submitting the same form twice records nothing
            # twice; the response says so in `already_recorded`.
            def create
              authorize!(:create, model_class)

              transfer, already_recorded = Spree::BankPayments::RecordManualTransfer.call(
                payment_method: store_bank_transfer_method(params[:payment_method_id]),
                amount: params[:amount], currency: params[:currency], reference: params[:reference],
                payer_name: params[:payer_name], occurred_at: params[:occurred_at],
                recorded_by: current_user
              )

              render json: serialize_resource(transfer).merge('already_recorded' => already_recorded),
                     status: :created
            rescue ActiveModel::ValidationError => e
              render_errors(errors_by_api_field(e.model.errors))
            end

            protected

            def model_class
              Spree::BankPayments::IncomingTransfer
            end

            def serializer_class
              IncomingTransferSerializer
            end

            def read_actions
              %w[index show suggestions]
            end

            def collection_includes
              [:bank_account, { payment_session: :order }]
            end

            # Unmatched unless the request filters on state: the queue is
            # what staff open this for.
            def ransack_params
              filters = super
              filters = filters.to_h.stringify_keys
              filters['state_eq'] = 'unmatched' unless filters.keys.any? { |key| key.start_with?('state_') }
              filters
            end

            # The store's bank transfer method with that prefixed id, or nil.
            def store_bank_transfer_method(id)
              return if id.blank?

              Spree::BankPayments::Gateway.where(store_id: current_store.id).find_by_prefix_id(id)
            end

            # The form's payment_method is the request's payment_method_id.
            def errors_by_api_field(errors)
              renamed = ActiveModel::Errors.new(errors.instance_variable_get(:@base))
              errors.each do |error|
                attribute = error.attribute == :payment_method ? :payment_method_id : error.attribute
                renamed.add(attribute, error.message)
              end
              renamed
            end

            def apply_collection_sort(collection)
              sort_param.present? ? collection : collection.order(occurred_at: :desc, id: :desc)
            end
          end
        end
      end
    end
  end
end
