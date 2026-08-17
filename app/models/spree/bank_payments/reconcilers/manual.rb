module Spree
  module BankPayments
    module Reconcilers
      # The default. An admin applies payments by hand from the transfers queue,
      # so there is nothing to poll and nothing that can become unhealthy.
      class Manual < Base
        def poll(since:)
          []
        end

        def parse_webhook(_raw_body, _headers)
          nil
        end

        # The manual reconciler never talks to anything, so it cannot be
        # unhealthy.
        def health
          :ok
        end

        def configured?
          true
        end

        # Manual stores create accounts by hand in the admin; there is
        # nothing to sync.
        def sync_accounts
          []
        end
      end
    end
  end
end
