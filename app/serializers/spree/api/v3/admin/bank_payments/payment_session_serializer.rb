module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # A bank transfer session as the order page shows it: the reference,
          # amount, deadline and bank details the buyer was quoted.
          class PaymentSessionSerializer < V3::BaseSerializer
            typelize reference: :string, status: :string, currency: :string, expires_at: [:string, nullable: true],
                     bank_details: 'Array<{ label?: string; fields: Array<{ label: string; value: string }> }>'

            money_attributes :amount
            attributes :reference, :status, :currency
            attribute(:expires_at) { |session| session.expires_at&.iso8601 }
            attribute(:bank_details) { |session| session.bank_detail_sets.map { |set| set.to_h.deep_stringify_keys } }
          end
        end
      end
    end
  end
end
