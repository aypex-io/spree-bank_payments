require 'spree_core'
require 'aypex_bank_transfer/version'
require 'aypex_bank_transfer/configuration'
require 'aypex_bank_transfer/engine'

module AypexBankTransfer
  def self.pg_trgm_available?
    return @pg_trgm_available if defined?(@pg_trgm_available)

    @pg_trgm_available = ActiveRecord::Base.connection.extension_enabled?('pg_trgm')
  rescue StandardError
    # Deliberately NOT memoized: a transient connection failure must not disable
    # payer-name suggestions for the lifetime of the process.
    false
  end
end
