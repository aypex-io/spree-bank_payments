module Spree
  module BankTransfer
    class Engine < ::Rails::Engine
      require 'spree/core'
      isolate_namespace Spree
      engine_name 'spree_bank_transfer'

      config.generators do |g|
        g.test_framework :rspec
      end

      initializer 'spree_bank_transfer.environment', before: :load_config_initializers do |_app|
        Spree::BankTransfer::Config = Spree::BankTransfer::Configuration.new
      end

      def self.activate
        # Three levels up from lib/spree/bank_transfer/ to reach the gem root.
        Dir.glob(File.join(File.dirname(__FILE__), '../../../app/**/*_decorator*.rb')) do |c|
          Rails.configuration.cache_classes ? require(c) : load(c)
        end
      end

      config.to_prepare(&method(:activate).to_proc)
    end
  end
end
