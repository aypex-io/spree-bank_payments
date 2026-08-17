module Spree
  module BankPayments
    # One set of payable coordinates for an account -- a local scheme, or SWIFT.
    #
    # `fields` is an ordered list of label/value pairs rather than named keys
    # because bank coordinates are not standardised: the UK uses a sort code and
    # account number, the US a routing number, Poland's Elixir something else
    # again. Named columns or fixed keys would mean a migration per market.
    class DetailSet
      # @param raw [Hash] anything that is not a Hash is treated as an empty
      #   detail set rather than raising. `details` is admin-editable JSON and
      #   provider-supplied data, so the shape is not guaranteed: a JSON object
      #   pasted where an array belongs arrives here as an `[key, value]` pair,
      #   and a provider following the README's old (wrong) `[[label, value]]`
      #   field shape arrives as an Array too. Both used to raise NoMethodError
      #   deep inside a validation or mid-sync. Unusable input must surface as
      #   a form error or a skipped account, never a 500.
      def initialize(raw)
        @raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
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
        # grep(Hash): a field entry that is not an object (e.g. the
        # `[label, value]` pair the README wrongly documented until 5.2.0) is
        # dropped, not raised on. An account whose every field is dropped is
        # simply not `usable?`.
        Array(@raw['fields']).grep(Hash).filter_map do |field|
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
