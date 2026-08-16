module Spree
  module BankPayments
    # The single value object crossing the reconciler boundary. Both ingress
    # paths — webhook and poll — return this, so matching is written once and
    # the two paths cannot drift apart.
    TransferData = Data.define(
      :provider,
      :provider_transaction_id,
      :amount,
      :currency,
      :reference,
      :payer_name,
      :occurred_at,
      :raw,
      :provider_account_id
    ) do
      def initialize(payer_name: nil, reference: nil, raw: {}, provider_account_id: nil, **rest)
        super(payer_name: payer_name, reference: reference, raw: raw,
              provider_account_id: provider_account_id, **rest)
      end
    end
  end
end
