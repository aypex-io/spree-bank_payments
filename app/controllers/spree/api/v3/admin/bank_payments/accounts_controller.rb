module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # The accounts a bank transfer payment method takes money into, under
          # /payment_methods/:payment_method_id/accounts.
          #
          # Offering an account withdraws the one already offered in its
          # currency. An account synced from a provider is the provider's: its
          # currency and details are refreshed by syncing, never edited, and it
          # is deactivated rather than deleted.
          class AccountsController < ResourceController
            DETAIL_SET_KEYS = [:label, :beneficiary_name, :beneficiary_address,
                               { schemes: [], fields: %i[label value] }].freeze

            # GET .../accounts/sync_plan
            #
            # What a sync would change, for staff to confirm before applying.
            def sync_plan
              authorize!(:read, model_class)
              render json: serialize_plan(Spree::BankPayments::SyncAccounts.new(payment_method: @payment_method).plan)
            rescue Spree::BankPayments::SyncAccounts::EmptyResponseError => e
              refuse_empty_sync(e)
            end

            # POST .../accounts/sync
            def sync
              authorize!(:update, model_class)
              Spree::BankPayments::SyncAccounts.new(payment_method: @payment_method).apply!
              render json: { data: serialize_collection(@payment_method.bank_accounts.reload.order(:currency, :id)) }
            rescue Spree::BankPayments::SyncAccounts::EmptyResponseError => e
              refuse_empty_sync(e)
            end

            def create
              authorize!(:create, model_class)
              account = @payment_method.bank_accounts.new(currency: params[:currency], details: detail_sets_param)

              if account.save
                render json: serialize_resource(account), status: :created
              else
                render_errors(account.errors)
              end
            end

            def update
              return refuse_synced if @resource.synced? && (params.key?(:currency) || params.key?(:details))

              attributes = params.permit(:offered, :active, :currency).to_h
              attributes[:details] = detail_sets_param if params.key?(:details)

              saved = model_class.transaction do
                withdraw_other_offered if ActiveModel::Type::Boolean.new.cast(attributes['offered'])
                @resource.update(attributes)
              end

              saved ? render(json: serialize_resource(@resource)) : render_errors(@resource.errors)
            end

            # A soft delete: a session already quoted the account still shows
            # its coordinates.
            def destroy
              return refuse_synced if @resource.synced?

              @resource.destroy
              head :no_content
            end

            protected

            def model_class
              Spree::BankPayments::BankAccount
            end

            def serializer_class
              BankAccountSerializer
            end

            def read_actions
              %w[index show sync_plan]
            end

            def set_parent
              @payment_method = find_payment_method!(params[:payment_method_id])
            end

            def store_scope
              model_class.where(payment_method_id: @payment_method.id)
            end

            def apply_collection_sort(collection)
              sort_param.present? ? collection : collection.order(:currency, :id)
            end

            private

            # One offered account per currency, enforced by a partial unique
            # index: the old one is withdrawn first, in the same transaction.
            def withdraw_other_offered
              @payment_method.bank_accounts.for_currency(@resource.currency).offered.
                where.not(id: @resource.id).update_all(offered: false, updated_at: Time.current)
            end

            def detail_sets_param
              Array(params.permit(details: DETAIL_SET_KEYS)[:details]).map { |set| set.to_h.deep_stringify_keys }
            end

            def serialize_plan(plan)
              reported = ->(data) { { 'provider_account_id' => data.provider_account_id, 'currency' => data.currency,
                                      'pooled' => data.pooled, 'detail_sets' => Array(data.details) } }

              {
                create: plan[:create].map(&reported),
                update: plan[:update].map(&reported),
                deactivate: serialize_collection(plan[:deactivate]),
                skipped: plan[:skipped].map(&reported)
              }
            end

            def refuse_synced
              render_error(code: 'synced_account', message: I18n.t('spree.bank_payments.errors.synced_account'),
                           status: :unprocessable_content)
            end

            def refuse_empty_sync(error)
              render_error(code: 'sync_empty', message: I18n.t('spree.bank_payments.errors.sync_empty', reason: error.message),
                           status: :unprocessable_content)
            end
          end
        end
      end
    end
  end
end
