module Spree
  module BankPayments
    # Records a transfer staff saw arrive outside any provider integration,
    # and runs it through the same matching as one a provider delivered. With
    # the default Manual reconciler this is the only way a transfer is ever
    # recorded.
    #
    # Its identity is derived from what was typed (gateway, amount, currency,
    # normalized reference, payer name ignoring case, date received), so
    # submitting the same form twice records nothing twice. The flip side:
    # two separate transfers identical in every one of those fields are one.
    class RecordManualTransfer
      PROVIDER = 'manual'.freeze

      # The typed input, validated as the form staff filled in.
      class Entry
        include ActiveModel::Model
        include ActiveModel::Validations

        attr_accessor :payment_method, :amount, :currency, :reference, :payer_name, :occurred_at, :time_zone

        validates :payment_method, presence: { message: :must_be_store_bank_transfer }
        validates :currency, presence: true
        validate :amount_positive
        validate :occurred_at_readable

        # Errors are reported against the API's field name.
        def self.human_attribute_name(attribute, options = {})
          attribute.to_s == 'payment_method' ? 'Payment method' : super
        end

        def amount_value
          BigDecimal(amount.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        # A bare date is the day the money arrived on the store's calendar,
        # so it is read in the store's time zone; a timestamp with an offset
        # names its own instant.
        def occurred_at_value
          return if occurred_at.to_s.strip.empty?

          zone.parse(occurred_at.to_s)
        rescue ArgumentError
          nil
        end

        # The date in the transfer's identity, as 6.0 derived it: the typed
        # day itself, or a timestamp's date in Time.zone. Reading the date in
        # the store's zone must not make a transfer recorded before look new.
        def identity_date
          typed = occurred_at.to_s.strip
          return Date.iso8601(typed) if typed.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          occurred_at_value.in_time_zone(Time.zone).to_date
        end

        private

        def zone
          ActiveSupport::TimeZone[time_zone.to_s] || Time.zone
        end

        def amount_positive
          errors.add(:amount, :greater_than, count: 0) unless amount_value&.positive?
        end

        def occurred_at_readable
          errors.add(:occurred_at, :invalid) if occurred_at_value.nil?
        end
      end

      # @param time_zone [String, nil] the store's time zone, which a bare
      #   date in +occurred_at+ is read in; Time.zone when nil
      # @return [Array(Spree::BankPayments::IncomingTransfer, Boolean)] the
      #   transfer, and whether it had already been recorded
      # @raise [ActiveModel::ValidationError] when the input is invalid
      def self.call(payment_method:, amount:, currency:, reference:, occurred_at:, payer_name: nil, recorded_by: nil,
                    time_zone: nil)
        entry = Entry.new(payment_method: payment_method, amount: amount, currency: currency,
                          reference: reference, payer_name: payer_name, occurred_at: occurred_at,
                          time_zone: time_zone)
        entry.validate!

        new(entry, recorded_by).call
      end

      def initialize(entry, recorded_by)
        @entry = entry
        @recorded_by = recorded_by
      end

      def call
        already_recorded = IncomingTransfer.exists?(provider: PROVIDER, provider_transaction_id: transaction_id)
        transfer = IngestTransfer.new(payment_method: entry.payment_method, transfer_data: transfer_data).call

        [transfer, already_recorded]
      end

      private

      attr_reader :entry, :recorded_by

      def currency
        entry.currency.to_s.strip.upcase
      end

      def transaction_id
        digest = Digest::SHA256.hexdigest([
          entry.payment_method.id,
          entry.amount_value.to_s('F'),
          currency,
          IncomingTransfer.normalize_reference(entry.reference),
          entry.payer_name.to_s.strip.downcase,
          entry.identity_date.iso8601
        ].join('|'))

        "#{PROVIDER}-#{digest[0, 32]}"
      end

      def transfer_data
        TransferData.new(
          provider: PROVIDER,
          provider_transaction_id: transaction_id,
          amount: entry.amount_value,
          currency: currency,
          reference: entry.reference.to_s.strip,
          payer_name: entry.payer_name.to_s.strip.presence,
          occurred_at: entry.occurred_at_value,
          raw: { 'source' => 'admin_manual_entry', 'recorded_by_id' => recorded_by&.id }
        )
      end
    end
  end
end
