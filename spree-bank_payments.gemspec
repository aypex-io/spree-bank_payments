lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'spree/bank_payments/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree-bank_payments'
  s.version     = Spree::BankPayments::VERSION
  s.summary     = 'Bank transfer checkout for Spree, with pluggable payment reconciliation'
  s.description = 'Adds a bank transfer payment method to Spree with an optional discount, ' \
                  'unique payment references, automatic reconciliation of incoming transfers, ' \
                  'and an admin queue for payments that cannot be matched automatically.'
  s.required_ruby_version = '>= 3.3'

  s.author   = 'Aypex'
  s.email    = 'hello@aypex.io'
  s.homepage = 'https://github.com/aypex-io/spree-bank_payments'
  s.license  = 'MIT'

  s.metadata = {
    'source_code_uri' => s.homepage,
    'bug_tracker_uri' => "#{s.homepage}/issues",
    'changelog_uri' => "#{s.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  s.files = Dir['{app,config,db,lib}/**/*', 'LICENSE', 'Rakefile', 'README.md', 'CHANGELOG.md']
  s.require_path = 'lib'

  # The major version tracks Spree's: 6.x supports Spree 6. Spree 5.6 stays on
  # 5.3.x, on the 5-3-stable branch. Spree 6 has no Rails admin (spree_admin
  # stops at 5.6), so there is no admin dependency: the dashboard screens ship
  # as a separate dashboard plugin package against this gem's Admin API.
  s.add_dependency 'spree', '~> 6.0'
end
