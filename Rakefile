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
  Rake::Task['extension:test_app'].execute(install_storefront: true, install_admin: true)
end
