module AypexBankTransfer
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

      def healthy?
        true
      end

      def configured?
        true
      end
    end
  end
end
