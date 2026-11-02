module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # An observed transfer, as the hand-match queue shows it.
          class IncomingTransferSerializer < V3::BaseSerializer
            typelize state: :string, currency: :string, provider: :string,
                     reference: [:string, nullable: true], payer_name: [:string, nullable: true],
                     occurred_at: :string, applied_at: [:string, nullable: true],
                     ignored_reason: [:string, nullable: true],
                     payment_method_id: [:string, nullable: true], payment_session_id: [:string, nullable: true],
                     bank_account: '{ id: string; currency: string; provider_account_id: string | null; pooled: boolean } | null',
                     order: '{ id: string; number: string } | null'

            money_attributes :amount
            attributes :state, :currency, :provider, :payer_name, :ignored_reason
            prefixed_id_attributes :payment_method, :payment_session

            # As the payer typed it; matching compares the normalized form.
            attribute(:reference, &:reference_raw)
            attribute(:occurred_at) { |transfer| transfer.occurred_at&.iso8601 }
            attribute(:applied_at) { |transfer| transfer.applied_at&.iso8601 }

            attribute :bank_account do |transfer|
              account = transfer.bank_account
              next if account.nil?

              {
                'id' => account.prefixed_id,
                'currency' => account.currency,
                'provider_account_id' => account.provider_account_id,
                'pooled' => account.pooled?
              }
            end

            attribute :order do |transfer|
              order = transfer.payment_session&.order
              next if order.nil?

              { 'id' => order.prefixed_id, 'number' => order.number }
            end
          end
        end
      end
    end
  end
end
