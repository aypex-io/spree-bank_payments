require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'open3'

# I1. PostgreSQL DDL is transactional: if `CREATE EXTENSION` raises
# insufficient_privilege inside the migrator's DDL transaction, the rescue
# runs but the migrator's own INSERT into schema_migrations then fails with
# PG::InFailedSqlTransaction and `rails db:migrate` hard-fails. That is
# exactly the host the rescue was written for (any role without CREATE on the
# database -- standard on RDS), so the "degradation" blocked installation.
# `disable_ddl_transaction!` is the fix: the rejected statement autocommits
# on its own and poisons nothing.
#
# Proving that in-process is impossible here, and the two failed attempts are
# worth recording so nobody "simplifies" this back:
#
#   1. Stubbing the migration class does nothing.
#      ActiveRecord::MigrationProxy#load_migration calls
#      `Object.send(:remove_const, name)` and re-`load`s the file immediately
#      before running it, so the stub is discarded and the REAL, succeeding
#      CREATE EXTENSION runs -- a green spec proving nothing.
#   2. Stubbing the adapter works, but the suite wraps every example in a
#      DatabaseCleaner `:transaction`. The rejected statement then poisons
#      *that* transaction, so the example fails for a reason with no
#      production analogue, and `use_transactional_tests = false` cannot opt
#      out of spree_dev_tools' global `around(:each)`.
#
# So the real thing is exercised in a subprocess: no test transaction, the
# real migrator, a real connection, and a statement PostgreSQL genuinely
# rejects standing in for insufficient_privilege (identical mechanics -- any
# failed statement poisons an open transaction the same way).
RSpec.describe 'EnablePgTrgm migration', type: :migration do
  GEM_ROOT = File.expand_path('../..', __dir__)
  MIGRATION_FILE = File.join(GEM_ROOT, 'db/migrate/20260815000003_enable_pg_trgm.rb')
  MIGRATION_VERSION = 20_260_815_000_003

  # Boots the dummy app, forces pg_trgm creation to fail at the adapter, and
  # runs the real migrator over a directory holding just this migration.
  PROBE_SCRIPT = <<~RUBY.freeze
    ENV['RAILS_ENV'] = 'test'
    require File.expand_path('spec/dummy/config/environment.rb', #{GEM_ROOT.inspect})

    module ForceExtensionFailure
      def enable_extension(name, **)
        return super unless name.to_s == 'pg_trgm'

        execute(%(CREATE EXTENSION "aypex_no_such_extension"))
      end
    end
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(ForceExtensionFailure)

    version = #{MIGRATION_VERSION}
    pool = ActiveRecord::Base.connection_pool
    begin
      pool.schema_migration.delete_version(version.to_s)
    rescue StandardError
      nil
    end

    begin
      ActiveRecord::MigrationContext.new(ARGV[0]).migrate
      puts "MIGRATE_RAISED=false"
    rescue StandardError => e
      puts "MIGRATE_RAISED=true"
      puts "ERROR_CLASS=\#{e.class}"
    end

    recorded = begin
      pool.schema_migration.integer_versions.include?(version)
    rescue StandardError
      false
    end
    puts "RECORDED=\#{recorded}"

    usable = begin
      ActiveRecord::Base.connection.select_value('SELECT 1') == 1
    rescue StandardError
      false
    end
    puts "CONNECTION_USABLE=\#{usable}"

    begin
      pool.schema_migration.delete_version(version.to_s)
    rescue StandardError
      nil
    end
  RUBY

  # @param strip_disable_ddl_transaction [Boolean] when true, writes the
  #   migration WITHOUT `disable_ddl_transaction!` -- the pre-fix code -- so
  #   the counterfactual can be observed rather than argued.
  def run_probe(strip_disable_ddl_transaction: false)
    Dir.mktmpdir do |dir|
      source = File.read(MIGRATION_FILE)
      if strip_disable_ddl_transaction
        source = source.sub(/^\s*disable_ddl_transaction!\s*$/, '')
        raise 'disable_ddl_transaction! not found in the migration' if source.include?('disable_ddl_transaction!')
      end

      File.write(File.join(dir, File.basename(MIGRATION_FILE)), source)

      script = File.join(dir, 'probe.rb')
      File.write(script, PROBE_SCRIPT)

      stdout, stderr, status = Open3.capture3(
        { 'RAILS_ENV' => 'test' }, 'bundle', 'exec', 'ruby', script, dir, chdir: GEM_ROOT
      )

      { stdout: stdout, stderr: stderr, status: status }
    end
  end

  it 'is declared to run outside a DDL transaction' do
    Dir.mktmpdir do |dir|
      FileUtils.cp(MIGRATION_FILE, File.join(dir, File.basename(MIGRATION_FILE)))
      migration = ActiveRecord::MigrationContext.new(dir).migrations.first.send(:migration)

      expect(migration.disable_ddl_transaction).to be true
    end
  end

  context 'when the role cannot create the extension (real subprocess, no test transaction)' do
    it 'completes the migration, degrades with a message, and records the version' do
      result = run_probe

      # Proves the failing branch is what ran -- not a stub that quietly
      # failed to bind and let the real CREATE EXTENSION succeed.
      expect(result[:stdout]).to include('Could not enable pg_trgm')
      expect(result[:stdout]).to include('MIGRATE_RAISED=false')
      expect(result[:stdout]).to include('RECORDED=true')
      expect(result[:stdout]).to include('CONNECTION_USABLE=true')
    end

    # The counterfactual. Without `disable_ddl_transaction!` this is the
    # reported bug verbatim: the rescue runs, then schema_migrations blows up
    # with PG::InFailedSqlTransaction and db:migrate hard-fails. If this ever
    # goes green, the example above has stopped proving anything.
    it 'hard-fails without disable_ddl_transaction!, which is the bug being fixed' do
      result = run_probe(strip_disable_ddl_transaction: true)

      expect(result[:stdout]).to include('MIGRATE_RAISED=true')
      expect(result[:stdout]).to include('RECORDED=false')
    end
  end

  context 'when the extension is not available on the server at all' do
    before do
      # Make the migration's own pg_available_extensions pre-check come back
      # empty, leaving every other query untouched. No statement fails here,
      # so this one is safe to run in-process.
      allow_any_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).
        to receive(:select_value).and_wrap_original do |original, sql, *rest, &block|
          if sql.to_s.include?('pg_available_extensions')
            nil
          else
            original.call(sql, *rest, &block)
          end
        end
    end

    it 'skips the attempt entirely rather than erroring' do
      expect_any_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).
        not_to receive(:enable_extension)

      Dir.mktmpdir do |dir|
        FileUtils.cp(MIGRATION_FILE, File.join(dir, File.basename(MIGRATION_FILE)))

        was_verbose = ActiveRecord::Migration.verbose
        ActiveRecord::Migration.verbose = true
        original_stdout = $stdout
        $stdout = StringIO.new

        begin
          ActiveRecord::MigrationContext.new(dir).migrate
          output = $stdout.string
        ensure
          $stdout = original_stdout
          ActiveRecord::Migration.verbose = was_verbose
        end

        expect(output).to include('pg_trgm is not available')
      end
    end
  end
end
