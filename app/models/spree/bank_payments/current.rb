module Spree
  module BankPayments
    # Request-scoped flags. `applying_transfer` marks the capture
    # ApplyTransfer runs, the only capture of a bank transfer payment
    # Spree::BankPayments::GuardCapture lets through.
    class Current < ActiveSupport::CurrentAttributes
      attribute :applying_transfer
    end
  end
end
