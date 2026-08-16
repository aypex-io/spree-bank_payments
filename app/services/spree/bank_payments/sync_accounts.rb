module Spree
  module BankPayments
    # Reconciles provider-reported accounts against BankAccount rows.
    #
    # Never sets `offered` -- that is the admin's checklist -- and never touches
    # bank_account_id on existing sessions: historical quotes are immutable,
    # because changing what a customer was told after the fact makes a dispute
    # unwinnable.
    class SyncAccounts
      class EmptyResponseError < StandardError; end

      def initialize(payment_method:)
        @payment_method = payment_method
      end

      # @return [Hash] :create, :update, :deactivate, :skipped
      def plan
        reported = payment_method.reconciler.sync_accounts
        existing = payment_method.bank_accounts.to_a

        # An auth failure that returns [] must not be read as "every account
        # disappeared" -- that would deactivate them all in one pass and
        # silently withdraw bank transfer from the storefront.
        raise EmptyResponseError, 'provider reported no accounts' if reported.empty? && existing.any?

        usable, unusable = reported.partition { |a| usable?(a) }

        by_id = existing.index_by(&:provider_account_id)

        # A soft-deleted account is an admin's deliberate decision to
        # withdraw it (see MigrateLegacyAccounts), not an absence for sync to
        # silently refill just because the provider still reports it. Route
        # these to :skipped rather than :create so they're visible, not lost.
        # Scoped to ids with no *live* counterpart: the partial unique index
        # deliberately allows a soft-deleted row and a live row to share a
        # provider id, and a soft-delete on the old row must not shadow a
        # live row an admin re-added under the same id -- that would pull
        # the live row's id out of `seen` below and deactivate it.
        soft_deleted_ids = payment_method.bank_accounts.only_deleted.pluck(:provider_account_id).to_set
        soft_deleted_ids -= by_id.keys
        usable, resurrections = usable.partition { |a| soft_deleted_ids.exclude?(a.provider_account_id) }

        seen = usable.map(&:provider_account_id)

        {
          create: usable.reject { |a| by_id.key?(a.provider_account_id) },
          update: usable.select { |a| by_id.key?(a.provider_account_id) },
          deactivate: existing.select { |a| a.provider_account_id.present? && seen.exclude?(a.provider_account_id) },
          skipped: unusable + resurrections
        }
      end

      # @param additive_only [Boolean] skip deactivations. Used by the consent
      #   re-approval trigger, which fires mid-OAuth-redirect: creating and
      #   refreshing accounts is always safe, but withdrawing a currency from
      #   the storefront needs a human looking at a diff.
      #
      # Deliberately takes no `prepared`/plan argument: a caller-supplied
      # plan could be built long before it's applied (e.g. held across an
      # admin request), and that staleness is exactly what the empty-response
      # abort guard in #plan exists to catch. Always deriving the plan here,
      # in the same call, means the guard can't be bypassed structurally --
      # see the "does not build and hold a plan" spec on the admin controller.
      def apply!(additive_only: false)
        prepared = plan

        ActiveRecord::Base.transaction do
          prepared[:create].each do |data|
            payment_method.bank_accounts.create!(
              provider_account_id: data.provider_account_id,
              currency: data.currency,
              details: data.details,
              offered: false,
              active: true,
              synced_at: Time.current
            )
          end

          prepared[:update].each do |data|
            account = payment_method.bank_accounts.find_by(provider_account_id: data.provider_account_id)
            account.update!(currency: data.currency, details: data.details,
                            active: true, synced_at: Time.current)
          end

          # Deactivate, never delete: sessions quoted against a retired account
          # must still render what the customer was told.
          unless additive_only
            prepared[:deactivate].each { |account| account.update!(active: false) }
          end
        end
      end

      private

      attr_reader :payment_method

      def usable?(data)
        Array(data.details).any? { |raw| DetailSet.new(raw).usable? }
      end
    end
  end
end
