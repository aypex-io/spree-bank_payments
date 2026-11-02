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
            before_action :set_resource, only: %i[show update destroy suggestions apply ignore]

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

            # POST /api/v3/admin/bank_payments/transfers/:id/apply
            #
            # Applies the transfer to the session staff chose. A transfer whose
            # amount or currency differs from the session's takes two
            # deliberate steps: the first request is refused with both
            # amounts, and only one carrying confirm_mismatch applies it,
            # credited for what actually arrived. A transfer is never applied
            # to another gateway's session, and another store's session is a
            # 404.
            def apply
              return refuse_applied if @resource.applied?

              payment_session = store_bank_transfer_session(params[:payment_session_id])
              return refuse_gateway_mismatch if gateway_mismatch?(payment_session)
              return refuse_amount_mismatch(payment_session) if money_mismatch?(payment_session) && !confirmed_mismatch?

              Spree::BankPayments::ApplyTransfer.call(
                transfer: @resource, payment_session: payment_session, applied_by: current_user
              )
              render json: serialize_resource(@resource.reload)
            rescue Spree::BankPayments::ApplyTransfer::Refused => e
              render_error(code: 'apply_refused', message: e.message, status: :unprocessable_content)
            end

            # POST /api/v3/admin/bank_payments/transfers/:id/ignore
            #
            # Takes the transfer out of the queue, with the reason staff give.
            def ignore
              return refuse_applied if @resource.applied?

              Spree::BankPayments::IgnoreTransfer.call(transfer: @resource, reason: params[:reason])
              render json: serialize_resource(@resource)
            rescue ActiveModel::ValidationError => e
              render_errors(e.model.errors)
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

            def authorize_resource!(resource = @resource, action = action_name.to_sym)
              super(resource, %w[apply ignore].include?(action.to_s) ? :update : action)
            end

            # A bank transfer session on one of this store's orders, or a 404.
            def store_bank_transfer_session(id)
              Spree::PaymentSessions::BankTransfer.
                joins(:order).where(spree_orders: { store_id: current_store.id }).
                find_by_prefix_id!(id)
            end

            def gateway_mismatch?(payment_session)
              @resource.payment_method_id.present? && @resource.payment_method_id != payment_session.payment_method_id
            end

            def money_mismatch?(payment_session)
              @resource.amount != payment_session.amount || !@resource.currency.casecmp?(payment_session.currency.to_s)
            end

            def confirmed_mismatch?
              ActiveModel::Type::Boolean.new.cast(params[:confirm_mismatch]) == true
            end

            def refuse_applied
              render_error(code: 'already_applied', message: I18n.t('spree.bank_payments.errors.already_applied'),
                           status: :unprocessable_content)
            end

            def refuse_gateway_mismatch
              render_error(code: 'gateway_mismatch', message: I18n.t('spree.bank_payments.errors.gateway_mismatch'),
                           status: :unprocessable_content)
            end

            def refuse_amount_mismatch(payment_session)
              render_error(
                code: 'amount_mismatch',
                message: I18n.t('spree.bank_payments.errors.amount_mismatch'),
                details: {
                  transfer_amount: Spree::Money::Rounding.format(@resource.amount, @resource.currency),
                  transfer_currency: @resource.currency,
                  session_amount: Spree::Money::Rounding.format(payment_session.amount, payment_session.currency),
                  currency: payment_session.currency
                },
                status: :unprocessable_content
              )
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
