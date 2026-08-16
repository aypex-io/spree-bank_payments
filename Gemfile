source 'https://rubygems.org'

gemspec

# `gemspec` only requires the gem's own lib entrypoint (which requires
# spree_core); it does not auto-`require` runtime dependencies pulled in
# transitively. spree_admin's admin routes/controllers are only loaded when
# the gem is actually required, so list it explicitly -- otherwise every
# admin route (edit_admin_payment_method_path etc.) is silently absent in
# the dummy app, matching the convention in other Spree extensions.
gem 'spree_admin'

gem 'pg'
gem 'propshaft'
