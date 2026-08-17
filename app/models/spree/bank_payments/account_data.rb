module Spree
  module BankPayments
    # One account as reported by a provider, in the gem's normalised shape.
    # The reconciler maps its provider's response into this -- the database and
    # views never see provider-specific schemas.
    #
    # `pooled` marks an account whose coordinates are shared with other
    # customers of the provider, so the payment reference is the only thing
    # separating two payers. Defaults to false: every provider written before
    # 5.3.0 omits it, and a dedicated account is the safe assumption.
    AccountData = Data.define(:provider_account_id, :currency, :details, :pooled) do
      def initialize(details: [], pooled: false, **rest)
        super(details: details, pooled: pooled, **rest)
      end
    end
  end
end
