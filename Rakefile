require 'bundler'
Bundler::GemHelper.install_tasks

require 'rspec/core/rake_task'
require 'spree/testing_support/extension_rake'

RSpec::Core::RakeTask.new

task :default do
  if Dir['spec/dummy'].empty?
    Rake::Task[:test_app].invoke
    Dir.chdir('../../')
  end
  Rake::Task['dummy:verify_schema'].invoke
  Rake::Task[:spec].invoke
end

desc 'Generates a dummy app for testing'
task :test_app do
  # Must be the require path, not the gem name: spree_core's common:test_app does a
  # literal `require ENV['LIB_NAME']`, templates the same string into the generated
  # dummy app, and constantizes "#{LIB_NAME.camelize}::Generators::InstallGenerator"
  # -- which only resolves to Spree::BankPayments::Generators::InstallGenerator when
  # this is the slash form.
  ENV['LIB_NAME'] = 'spree/bank_payments'
  # This gem is PostgreSQL-only: jsonb, partial indexes and pg_trgm are all
  # load-bearing. Default the harness accordingly so a bare `rake test_app`
  # cannot silently build a SQLite app on which none of them are real.
  ENV['DB'] ||= 'postgres'
  # extension:test_app (spree_core) generates the dummy app, migrates Spree's own
  # schema, then auto-loads generators/spree/bank_payments/install/install_generator
  # and runs it with --auto-run-migrations. That generator copies *only* this gem's
  # migrations (scoped via `rake spree_bank_payments:install:migrations`, not the
  # unscoped `railties:install:migrations`) and runs db:migrate, so a fresh
  # `rake test_app` needs no manual migration step.
  # Spree 6's extension:test_app takes no install_admin or install_storefront
  # option: there is no Rails admin or storefront to install.
  Rake::Task['extension:test_app'].execute
end

namespace :dummy do
  # Spree's test_app task runs `db:migrate` in the generator's own process with
  # output redirected to /dev/null and its exit status ignored. If a migration
  # fails partway (Spree's preferences conversion eager loads the whole app, so
  # any class that fails to load stops it), the dummy database is left
  # half-built and the suite errors with "Could not find table 'spree_*'" and
  # no hint of the cause. Rebuild it from the migration files, in a fresh
  # process and visibly, and fail fast with the real error.
  desc 'Ensure the dummy app database schema is fully migrated'
  task :verify_schema do
    dummy_path = File.expand_path('spec/dummy', __dir__)
    next unless File.directory?(dummy_path)

    # Keep using the gem's bundle after the chdir below.
    ENV['BUNDLE_GEMFILE'] = File.expand_path(ENV['BUNDLE_GEMFILE'], __dir__) if ENV['BUNDLE_GEMFILE']
    ENV['RAILS_ENV'] = 'test'

    Dir.chdir(dummy_path) do
      puts 'Rebuilding dummy app database schema...'

      # A possibly truncated dump must not stand in for the migration files.
      schema = File.join(dummy_path, 'db', 'schema.rb')
      File.delete(schema) if File.exist?(schema)

      # Separate invocations on purpose: chaining db:create and db:migrate in
      # one `rails` call can leave migrate reading a stale schema state.
      system('bundle exec rails db:drop db:create')
      next if system('bundle exec rails db:migrate')

      abort 'Dummy app database setup failed; aborting before running specs. ' \
            'See the migration output above for the underlying error.'
    end
  end
end
