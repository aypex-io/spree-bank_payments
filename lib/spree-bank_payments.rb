# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-bank_payments"` in a host
# Gemfile issues `require "spree-bank_payments"`. The gem's real entry point is
# `spree/bank_payments` (matching the Spree::BankPayments namespace), so this shim
# keeps the default `Bundler.require` working without every consumer having to write
# `gem "spree-bank_payments", require: "spree/bank_payments"`.
require 'spree/bank_payments'
