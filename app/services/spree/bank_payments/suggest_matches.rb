module Spree
  module BankPayments
    # Ranks candidate sessions for an unmatched transfer so an admin can decide.
    # Never applies anything.
    class SuggestMatches
      LIMIT = 5
      NAME_SIMILARITY_THRESHOLD = 0.3

      def initialize(transfer:)
        @transfer = transfer
      end

      def call
        exact = amount_matches.limit(LIMIT).to_a
        return exact if exact.length >= LIMIT

        (exact + name_matches(exclude: exact)).uniq.first(LIMIT)
      end

      private

      attr_reader :transfer

      # Scoped to the transfer's own gateway. Since Spree::PaymentMethod
      # belongs to exactly one store, this also pins suggestions to the
      # transfer's store -- without it, another store's order numbers and
      # amounts would render in this store's admin queue (and the "apply"
      # buttons would then bounce off the store guard in the controller with
      # a confusing "could not be found"). A transfer with no known gateway
      # (payment_method_id nil) gets no suggestions rather than an unscoped,
      # cross-store guess.
      def open_sessions
        return ::Spree::PaymentSessions::BankTransfer.none if transfer.payment_method_id.blank?

        ::Spree::PaymentSessions::BankTransfer.open.where(payment_method_id: transfer.payment_method_id)
      end

      def amount_matches
        open_sessions.where(amount: transfer.amount, currency: transfer.currency).
          order(created_at: :desc)
      end

      def name_matches(exclude:)
        return [] unless Spree::BankPayments.pg_trgm_available?
        return [] if transfer.payer_name.blank?

        open_sessions.
          where.not(id: exclude.map(&:id)).
          joins(order: :bill_address).
          where(
            "similarity(concat_ws(' ', spree_addresses.firstname, spree_addresses.lastname), ?) > ?",
            transfer.payer_name, NAME_SIMILARITY_THRESHOLD
          ).
          order(
            Arel.sql(
              ActiveRecord::Base.sanitize_sql_array([
                "similarity(concat_ws(' ', spree_addresses.firstname, spree_addresses.lastname), ?) DESC",
                transfer.payer_name
              ])
            )
          ).
          limit(LIMIT).to_a
      end
    end
  end
end
