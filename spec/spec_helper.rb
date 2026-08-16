ENV['RAILS_ENV'] = 'test'

require File.expand_path('../dummy/config/environment.rb', __FILE__)
require 'spree_dev_tools/rspec/spec_helper'
require 'aypex_bank_transfer/factories'

# spree_admin is a gemspec *runtime* dependency, not a direct Gemfile entry,
# and Bundler.require(*Rails.groups) only auto-requires gems declared
# directly in the Gemfile -- gemspec dependencies are resolved/installed but
# not auto-required. That gap meant every admin-adjacent spec silently ran
# against a dummy app with no admin routes/controllers at all (see the
# Task 12 bank_transfer_configuration_spec.rb fix). Fail loudly, at boot, if
# this regresses instead of letting a future admin spec fail confusingly
# with an undefined route helper.
raise 'spree_admin is not loaded -- check the Gemfile requires it directly (not just via `gemspec`)' unless defined?(Spree::Admin::Engine)

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].sort.each { |f| require f }
