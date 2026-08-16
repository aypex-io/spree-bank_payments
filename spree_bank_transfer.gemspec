lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'spree_bank_transfer/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree_bank_transfer'
  s.version     = SpreeBankTransfer::VERSION
  s.summary     = 'Bank transfer checkout for Spree, with pluggable payment reconciliation'
  s.description = 'Adds a bank transfer payment method to Spree with an optional discount, ' \
                  'unique payment references, automatic reconciliation of incoming transfers, ' \
                  'and an admin queue for payments that cannot be matched automatically.'
  s.required_ruby_version = '>= 3.3'

  s.author   = 'Aypex'
  s.email    = 'hello@aypex.io'
  s.homepage = 'https://github.com/aypex-io/spree_bank_transfer'
  s.license  = 'MIT'

  s.files = Dir['{app,config,db,lib}/**/*', 'LICENSE', 'Rakefile', 'README.md']
  s.require_path = 'lib'

  spree_opts = '>= 5.6.0'
  s.add_dependency 'spree', spree_opts
  s.add_dependency 'spree_admin', spree_opts

  s.add_development_dependency 'spree_dev_tools'
  s.add_development_dependency 'webmock'
end
