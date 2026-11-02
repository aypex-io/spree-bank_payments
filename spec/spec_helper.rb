ENV['RAILS_ENV'] = 'test'

require File.expand_path('../dummy/config/environment.rb', __FILE__)
require 'spree_dev_tools/rspec/spec_helper'
require 'spree/bank_payments/factories'

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].sort.each { |f| require f }
