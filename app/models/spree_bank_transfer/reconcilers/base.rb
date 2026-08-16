module SpreeBankTransfer
  module Reconcilers
    class Base
      class NotConfiguredError < StandardError; end

      class << self
        def registry
          @registry ||= {}
        end

        def register(key, klass)
          registry[key.to_s] = klass
        end

        def build(payment_method:)
          key = payment_method.preferred_reconciler.to_s
          klass = registry.fetch(key) do
            raise ArgumentError, "unknown reconciler #{key.inspect}"
          end

          klass.new(payment_method: payment_method)
        end
      end

      attr_reader :payment_method

      def initialize(payment_method:)
        @payment_method = payment_method
      end

      # @param since [Time]
      # @return [Array<SpreeBankTransfer::TransferData>]
      def poll(since:)
        raise NotImplementedError, "#{self.class} must implement #poll"
      end

      # @return [SpreeBankTransfer::TransferData, nil] nil for unsupported events
      # @raise [Spree::PaymentMethod::WebhookSignatureError]
      def parse_webhook(raw_body, headers)
        raise NotImplementedError, "#{self.class} must implement #parse_webhook"
      end

      # @return [Boolean] false means the expiry job must not cancel anything
      def healthy?
        raise NotImplementedError, "#{self.class} must implement #healthy?"
      end

      # @return [Boolean] whether credentials and settings are complete
      def configured?
        raise NotImplementedError, "#{self.class} must implement #configured?"
      end
    end
  end
end
