module Spree
  module Api
    module V3
      module Admin
        module BankPayments
          # An open bank transfer session an unmatched transfer could belong
          # to. `id` is the session's. Pass the transfer as `params[:transfer]`
          # so `exact_match` can be worked out.
          class SuggestionSerializer < V3::BaseSerializer
            typelize reference: :string, currency: :string, expires_at: [:string, nullable: true],
                     exact_match: :boolean,
                     order: '{ id: string; number: string; email: string | null; customer_name: string | null }'

            money_attributes :amount
            attributes :reference, :currency
            attribute(:expires_at) { |session| session.expires_at&.iso8601 }

            attribute :exact_match do |session|
              transfer = params[:transfer]
              transfer.present? && session.amount == transfer.amount &&
                session.currency.casecmp?(transfer.currency.to_s)
            end

            attribute :order do |session|
              order = session.order
              address = order.bill_address

              {
                'id' => order.prefixed_id,
                'number' => order.number,
                'email' => order.email,
                'customer_name' => [address&.first_name, address&.last_name].compact.join(' ').presence
              }
            end
          end
        end
      end
    end
  end
end
