# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-bank_transfer"` in a host
# Gemfile issues `require "spree-bank_transfer"`. The gem's real entry point is
# `spree/bank_transfer` (matching the Spree::BankTransfer namespace), so this shim
# keeps the default `Bundler.require` working without every consumer having to write
# `gem "spree-bank_transfer", require: "spree/bank_transfer"`.
require 'spree/bank_transfer'
