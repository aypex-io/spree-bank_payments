module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # An account money can arrive in. Customers are quoted only the
          # offered one per currency; every active account is watched.
          class BankAccountSerializer < V3::BaseSerializer
            typelize currency: :string, offered: :boolean, active: :boolean, pooled: :boolean,
                     synced: :boolean, provider_account_id: [:string, nullable: true],
                     detail_sets: 'Array<{ label?: string; schemes?: string[]; beneficiary_name?: string; ' \
                                  'beneficiary_address?: string; fields: Array<{ label: string; value: string }> }>'

            attributes :currency, :offered, :active, :pooled, :provider_account_id
            attribute(:synced, &:synced?)
            attribute(:detail_sets) { |account| Array(account.details) }
            attribute(:created_at) { |account| account.created_at&.iso8601 }
          end
        end
      end
    end
  end
end
