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

            def apply_collection_sort(collection)
              sort_param.present? ? collection : collection.order(occurred_at: :desc, id: :desc)
            end
          end
        end
      end
    end
  end
end
