module Spree
  module BankPayments
    # One set of payable coordinates for an account -- a local scheme, or SWIFT.
    #
    # `fields` is an ordered list of label/value pairs rather than named keys
    # because bank coordinates are not standardised: the UK uses a sort code and
    # account number, the US a routing number, Poland's Elixir something else
    # again. Named columns or fixed keys would mean a migration per market.
    class DetailSet
      def initialize(raw)
        @raw = (raw || {}).transform_keys(&:to_s)
      end

      def label
        @raw['label'].presence
      end

      def schemes
        Array(@raw['schemes']).map(&:to_s)
      end

      def beneficiary_name
        @raw['beneficiary_name'].presence
      end

      def beneficiary_address
        @raw['beneficiary_address']
      end

      # @return [Array<Array(String, String)>] ordered [label, value] pairs
      def fields
        Array(@raw['fields']).filter_map do |field|
          f = field.transform_keys(&:to_s)
          value = f['value'].to_s.strip
          next if value.empty?

          [f['label'].to_s, value]
        end
      end

      def usable?
        fields.any?
      end

      def to_h
        @raw
      end
    end
  end
end
