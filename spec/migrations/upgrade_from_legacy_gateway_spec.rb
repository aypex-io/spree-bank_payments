require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

# C1. The legacy data migration could not run on the only kind of store it
# exists for.
#
# `MigrateLegacyAccounts` runs application code, and `BankAccount` is
# `acts_as_paranoid` -- so every query it issues (the offered-per-currency
# uniqueness validation, `bank_accounts.with_deleted`) references `deleted_at`.
# While the data migration was numbered before the migration that ADDS
# `deleted_at`, `rails db:migrate` on a real 5.1.1 store with a configured
# gateway died with PG::UndefinedColumn and the upgrade halted.
#
# It passed review because every existing test asserts the *end state*: the
# legacy spec calls the service directly against the final schema, and a fresh
# dummy app has no gateway rows, so the data migration is a no-op there. The
# transition is what was untested, so the transition is what this file tests --
# a database at the 5.1.1 schema, holding a legacy gateway, migrated forward
# through the real installed migrations in their real order.
#
# In a subprocess against a scratch database, for the same reasons the pg_trgm
# spec gives: real migrator, real DDL, no DatabaseCleaner transaction to poison
# and no risk of ALTER TABLE deadlocking against the suite's own open
# transaction.
RSpec.describe 'upgrading a 5.1.1 store that has a legacy gateway', type: :migration do
  gem_root = File.expand_path('../..', __dir__)
  GEM_ROOT_FOR_UPGRADE = gem_root
  # The dummy app's copy, not db/migrate: this is what
  # `rails spree_bank_payments:install:migrations` actually produces in a host
  # app, which is where the ordering has to be right.
  DUMMY_MIGRATE_PATH = File.join(gem_root, 'spec/dummy/db/migrate')

  # Boots the dummy app, points it at a scratch database loaded from the dummy
  # schema, rolls the 5.2.0 migrations back off it to reach the 5.1.1 schema,
  # inserts a legacy gateway with flat account_* preferences, and then runs the
  # real migrator forward over ARGV[0].
  #
  # ARGV: [migration_path, database_name]
  UPGRADE_PROBE_SCRIPT = <<~RUBY.freeze
    ENV['RAILS_ENV'] = 'test'
    require 'stringio'
    require File.expand_path('spec/dummy/config/environment.rb', #{gem_root.inspect})

    forward_path, probe_db = ARGV
    dummy_path = #{File.join(gem_root, 'spec/dummy/db/migrate').inspect}

    # The migrator is noisy and this script's own markers are the contract.
    ActiveRecord::Migration.verbose = false
    # Without this, ActiveRecord::Schema#assume_migrated_upto_version resolves
    # migrations against the default "db/migrate" -- the *gem's* directory,
    # relative to cwd -- and records only a handful of versions, so the
    # rollback below silently reverts almost nothing.
    ActiveRecord::Migrator.migrations_paths = [dummy_path]

    base = ActiveRecord::Base.connection_db_config.configuration_hash

    ActiveRecord::Base.establish_connection(base.merge(database: 'postgres'))
    ActiveRecord::Base.connection.execute(%(DROP DATABASE IF EXISTS \#{probe_db}))
    ActiveRecord::Base.connection.execute(%(CREATE DATABASE \#{probe_db}))

    ActiveRecord::Base.establish_connection(base.merge(database: probe_db))
    ActiveRecord::Base.descendants.each { |k| k.reset_column_information rescue nil }

    # Load the 5.2.0 end state, then roll the 5.2.0 migrations back off it to
    # reach the 5.1.1 schema -- far faster than replaying every Spree core
    # migration, and identical in outcome. The rollback always runs against the
    # real installed directory; only the forward migration uses ARGV[0], so the
    # counterfactual cannot accidentally leave a column behind.
    original_stdout = $stdout
    $stdout = StringIO.new
    begin
      load File.expand_path('spec/dummy/db/schema.rb', #{gem_root.inspect})
    ensure
      $stdout = original_stdout
    end

    versions = Dir[File.join(dummy_path, '*.rb')].map { |f| File.basename(f).split('_').first.to_i }.sort
    accounts_file = Dir[File.join(dummy_path, '*create_spree_bank_payments_bank_accounts*.rb')].sole
    accounts_version = File.basename(accounts_file).split('_').first.to_i
    five_one_one = versions.select { |v| v < accounts_version }.max

    ActiveRecord::MigrationContext.new(dummy_path).migrate(five_one_one)
    ActiveRecord::Base.descendants.each { |k| k.reset_column_information rescue nil }

    puts "ROLLED_BACK_TO_5_1_1=\#{!ActiveRecord::Base.connection.table_exists?('spree_bank_payments_bank_accounts')}"

    store = Spree::Store.new(
      name: 'Probe Store', code: 'probe', url: 'probe.example.com',
      mail_from_address: 'probe@example.com', default_currency: 'GBP'
    )
    store.save!(validate: false) unless store.save

    gateway = Spree::BankPayments::Gateway.new(name: 'Bank Transfer', store: store)
    gateway.preferences = gateway.preferences.merge(
      reconciler: 'manual',
      account_name: 'Legacy Ltd',
      account_iban: 'GB00LEGACY000000000000',
      account_bic: 'LEGAGB21'
    )
    gateway.save!
    puts "GATEWAY_CREATED=true"

    begin
      ActiveRecord::MigrationContext.new(forward_path).migrate
      puts "MIGRATE_RAISED=false"
    rescue StandardError => e
      puts "MIGRATE_RAISED=true"
      puts "ERROR_CLASS=\#{e.class}"
      puts "ERROR_MESSAGE=\#{e.message.gsub(%(\n), ' | ')}"
    end

    begin
      ActiveRecord::Base.descendants.each { |k| k.reset_column_information rescue nil }
      account = Spree::BankPayments::BankAccount.where(payment_method_id: gateway.id).sole
      puts "ACCOUNT_COUNT=1"
      puts "ACCOUNT_CURRENCY=\#{account.currency}"
      puts "ACCOUNT_OFFERED=\#{account.offered}"
      puts "ACCOUNT_ACTIVE=\#{account.active}"
      puts "ACCOUNT_PROVIDER_ID=\#{account.provider_account_id.inspect}"
      puts "ACCOUNT_FIELDS=\#{account.detail_sets.first.fields.inspect}"
    rescue StandardError => e
      puts "ACCOUNT_LOOKUP_FAILED=\#{e.class}"
    end

    ActiveRecord::Base.establish_connection(base.merge(database: 'postgres'))
    ActiveRecord::Base.connection.execute(%(DROP DATABASE IF EXISTS \#{probe_db}))
  RUBY

  # @param reorder [Boolean] when true, renumbers the deleted_at and
  #   soft-delete-index migrations to run AFTER the data migration -- the
  #   pre-fix order -- so the counterfactual can be observed rather than argued.
  def run_probe(reorder: false, database:)
    Dir.mktmpdir do |dir|
      migrate_dir = File.join(dir, 'migrate')
      FileUtils.cp_r(DUMMY_MIGRATE_PATH, migrate_dir)

      reorder_migrations!(migrate_dir) if reorder

      script = File.join(dir, 'probe.rb')
      File.write(script, UPGRADE_PROBE_SCRIPT)

      stdout, stderr, status = Open3.capture3(
        { 'RAILS_ENV' => 'test' }, 'bundle', 'exec', 'ruby', script, migrate_dir, database,
        chdir: GEM_ROOT_FOR_UPGRADE
      )

      { stdout: stdout, stderr: stderr, status: status }
    end
  end

  # Moves the two soft-delete migrations to the end of the sequence, which is
  # exactly what the buggy numbering did relative to the data migration.
  def reorder_migrations!(dir)
    versions = Dir[File.join(dir, '*.rb')].map { |f| File.basename(f).split('_').first.to_i }
    next_version = versions.max + 1

    %w[add_deleted_at_to_spree_bank_payments_bank_accounts
       exclude_soft_deleted_from_bank_account_uniqueness].each do |name|
      file = Dir[File.join(dir, "*#{name}*.rb")].sole
      rest = File.basename(file).split('_', 2).last
      File.rename(file, File.join(dir, "#{next_version}_#{rest}"))
      next_version += 1
    end
  end

  it 'migrates a 5.1.1 database with a configured gateway all the way forward' do
    result = run_probe(database: 'spree_bank_payments_upgrade_probe')

    # Proves the fixture is the one described: a database rolled back to the
    # 5.1.1 schema, holding a real legacy gateway.
    expect(result[:stdout]).to include('ROLLED_BACK_TO_5_1_1=true'), result[:stderr]
    expect(result[:stdout]).to include('GATEWAY_CREATED=true'), result[:stderr]

    expect(result[:stdout]).to include('MIGRATE_RAISED=false'), result[:stdout] + result[:stderr]

    # And the data migration did its job on the way through.
    expect(result[:stdout]).to include('ACCOUNT_COUNT=1')
    expect(result[:stdout]).to include('ACCOUNT_CURRENCY=GBP')
    expect(result[:stdout]).to include('ACCOUNT_OFFERED=true')
    expect(result[:stdout]).to include('ACCOUNT_ACTIVE=true')
    expect(result[:stdout]).to include('ACCOUNT_PROVIDER_ID=nil')
    expect(result[:stdout]).to include(
      'ACCOUNT_FIELDS=[["Account name", "Legacy Ltd"], ["IBAN", "GB00LEGACY000000000000"], ["BIC", "LEGAGB21"]]'
    )
  end

  # The counterfactual. With the data migration numbered before the deleted_at
  # column -- the shipped order until this fix -- the upgrade halts on the
  # paranoid model's first query. If this ever goes green, the example above
  # has stopped proving anything.
  it 'halts on PG::UndefinedColumn if the data migration runs before deleted_at exists' do
    result = run_probe(reorder: true, database: 'spree_bank_payments_upgrade_probe_bug')

    expect(result[:stdout]).to include('MIGRATE_RAISED=true'), result[:stdout] + result[:stderr]
    expect(result[:stdout]).to include('deleted_at')
  end
end
