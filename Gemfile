source 'https://rubygems.org'

gemspec

gem 'pg'
gem 'propshaft'
gem 'webmock'

# Constrained here because the gemspec does not declare it; Bundler would
# otherwise resolve 0.6.3, which is broken on Spree 6.
gem 'spree_dev_tools', '~> 1.0'

# CI runs a matrix of Spree versions. SPREE_VERSION pins one (e.g. "6.0.0");
# left unset, Bundler resolves the newest release the gemspec allows.
spree_version = ENV.fetch('SPREE_VERSION', '')
gem 'spree', spree_version unless spree_version.empty?
