require 'spree/api/testing_support/v3/base'

# Spree's own Admin API specs are controller specs against the core engine's
# routes, with the shared contexts from spree/api/testing_support/v3/base
# ('API v3 Admin authenticated', 'API v3 Admin with custom permissions').
module AdminApiSpecHelpers
  extend ActiveSupport::Concern

  included do
    routes { Spree::Core::Engine.routes }
  end

  def json_response
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  config.include AdminApiSpecHelpers, type: :controller
end
