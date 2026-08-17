module Spree
  module BankPayments
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
        # @return [Array<Spree::BankPayments::TransferData>]
        def poll(since:)
          raise NotImplementedError, "#{self.class} must implement #poll"
        end

        # @return [Spree::BankPayments::TransferData, nil] nil for unsupported events
        # @raise [Spree::PaymentMethod::WebhookSignatureError]
        def parse_webhook(raw_body, headers)
          raise NotImplementedError, "#{self.class} must implement #parse_webhook"
        end

        HEALTH_STATES = %i[ok transient consent_revoked].freeze

        # @return [Symbol] one of HEALTH_STATES.
        #
        # :transient still offers at checkout -- a brief provider outage must
        # not pull bank transfer off the storefront, because the money still
        # arrives and reconciles once the provider returns. Only
        # :consent_revoked withdraws it, because in that state nothing will
        # ever reconcile.
        #
        # Providers written against <= 5.2 implement #healthy? only, so the
        # default derives from it.
        def health
          healthy? ? :ok : :transient
        end

        # @return [Boolean] false means the expiry job must not cancel anything
        #
        # Providers written against >= 5.3 may implement #health only, so the
        # default derives from it. The two defaults are mutually recursive by
        # construction; the owner check breaks the cycle and turns "overrode
        # neither" into a clear contract error instead of a SystemStackError.
        def healthy?
          if method(:health).owner == Spree::BankPayments::Reconcilers::Base
            raise NotImplementedError, "#{self.class} must implement #health or #healthy?"
          end

          health == :ok
        end

        # @return [Boolean] whether credentials and settings are complete
        def configured?
          raise NotImplementedError, "#{self.class} must implement #configured?"
        end

        # Accounts this provider can see, for the admin sync flow.
        # Providers that cannot enumerate accounts return [].
        #
        # @return [Array<Spree::BankPayments::AccountData>]
        def sync_accounts
          []
        end
      end
    end
  end
end
