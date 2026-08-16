module Spree
  module BankPayments
    # One account as reported by a provider, in the gem's normalised shape.
    # The reconciler maps its provider's response into this -- the database and
    # views never see provider-specific schemas.
    AccountData = Data.define(:provider_account_id, :currency, :details) do
      def initialize(details: [], **rest)
        super(details: details, **rest)
      end
    end
  end
end
