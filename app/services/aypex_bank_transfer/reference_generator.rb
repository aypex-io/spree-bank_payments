module AypexBankTransfer
  class ReferenceGenerator
    # Crockford base32: excludes I, L, O and U so handwritten and mistyped
    # references stay unambiguous.
    ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'.freeze
    LENGTH = 6
    MAX_ATTEMPTS = 10

    class ExhaustedError < StandardError; end

    def initialize(payment_method:)
      @payment_method = payment_method
    end

    def generate
      MAX_ATTEMPTS.times do
        candidate = "#{@payment_method.preferred_reference_prefix}#{random_code}"
        return candidate unless taken?(candidate)
      end

      raise ExhaustedError,
            "could not generate a unique reference after #{MAX_ATTEMPTS} attempts"
    end

    private

    def random_code
      Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
    end

    def taken?(candidate)
      normalized = IncomingTransfer.normalize_reference(candidate)

      ::Spree::PaymentSessions::BankTransfer.
        where(payment_method_id: @payment_method.id, external_id_normalized: normalized).
        exists?
    end
  end
end
