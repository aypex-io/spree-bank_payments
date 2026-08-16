module Spree
  module BankTransfer
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
      :raw
    ) do
      def initialize(payer_name: nil, reference: nil, raw: {}, **rest)
        super(payer_name: payer_name, reference: reference, raw: raw, **rest)
      end
    end
  end
end
