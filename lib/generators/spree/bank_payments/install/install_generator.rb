module Spree
  module BankPayments
    module Generators
      class InstallGenerator < Rails::Generators::Base
        desc 'Copies Spree::BankPayments migrations into the host application, runs them, ' \
             "and schedules the gem's jobs."

        # The jobs that must run on a schedule: without them nothing expires
        # and no reminder is sent. Each with its Solid Queue schedule and its
        # cron line. PollJob runs at the gateway's default poll interval (15
        # minutes); a gateway set to another interval needs its line changed.
        SCHEDULE = [
          ['bank_payments_expire_sessions', 'Spree::BankPayments::ExpireSessionsJob',
           'every hour at minute 23', '23 * * * *'],
          ['bank_payments_send_reminders', 'Spree::BankPayments::SendRemindersJob',
           'every day at 9am', '0 9 * * *'],
          ['bank_payments_poll', 'Spree::BankPayments::PollJob',
           'every 15 minutes', '*/15 * * * *']
        ].freeze

        class_option :auto_run_migrations,
                     type: :boolean,
                     default: false,
                     desc: 'Run the copied migrations immediately instead of asking'

        class_option :skip_migrations,
                     type: :boolean,
                     default: false,
                     desc: 'Copy and run no migrations, only schedule the jobs (on an existing install)'

        class_option :scheduler,
                     type: :string,
                     enum: %w[solid_queue sidekiq_cron none],
                     desc: "Where to schedule the jobs. Default: the app's Active Job adapter " \
                           '(Solid Queue, or Sidekiq with sidekiq-cron)'

        def copy_migrations
          return say_status(:skip, 'migrations (--skip-migrations)', :yellow) if options[:skip_migrations]

          # Scoped to this engine only: sets ENV["FROM"] = "spree_bank_payments" before
          # delegating to railties:install:migrations, so migrations pending on other
          # railties (e.g. action_mailbox, acts_as_taggable_on) are never touched.
          rake 'spree_bank_payments:install:migrations'
        end

        def run_migrations
          return if options[:skip_migrations]

          if run_migrations?
            rake 'db:migrate'
          else
            say_status :skip, 'db:migrate — remember to run it before using the gem', :yellow
          end
        end

        # Writes the jobs into config/recurring.yml (Solid Queue, what a stock
        # Spree 6 store runs) or config/schedule.yml (sidekiq-cron), leaving
        # the entries already there alone. Running it again adds nothing. A
        # file it cannot edit safely is left as it is, and the jobs are listed
        # for adding by hand: the edited file is parsed before it is written,
        # and must keep every entry it had.
        def add_schedule
          case scheduler
          when 'solid_queue' then schedule_in_solid_queue
          when 'sidekiq_cron' then schedule_in_sidekiq_cron
          else say_schedule_by_hand
          end
        end

        private

        RECURRING = 'config/recurring.yml'.freeze
        # sidekiq-cron loads schedule.yml, or schedule.yaml when there is no
        # schedule.yml. Writing a .yml beside a .yaml would switch it over, and
        # it then deletes the jobs the .yaml had scheduled.
        SIDEKIQ_CRON_FILES = %w[config/schedule.yml config/schedule.yaml].freeze

        def scheduler
          options[:scheduler] || detected_scheduler
        end

        # A Rails 8 app often sets Solid Queue in production.rb only, and the
        # generator runs in development: a bundled solid_queue with a
        # recurring.yml settles it.
        def detected_scheduler
          case Rails.application.config.active_job.queue_adapter.to_s
          when 'solid_queue' then 'solid_queue'
          when 'sidekiq' then bundled?('sidekiq-cron') ? 'sidekiq_cron' : 'none'
          else bundled?('solid_queue') && schedule_file?(RECURRING) ? 'solid_queue' : 'none'
          end
        end

        def bundled?(gem_name)
          schedule_file?('Gemfile.lock') && schedule_text('Gemfile.lock').match?(/^    #{Regexp.escape(gem_name)} \(/)
        end

        def schedule_in_solid_queue
          return create_file(RECURRING, "production:\n#{recurring_entries('  ')}") unless schedule_file?(RECURRING)
          return if already_scheduled?(RECURRING)

          original = schedule_text(RECURRING)
          updated = with_recurring_entries(original)
          return write_schedule(RECURRING, updated) if updated && recurring_kept?(original, updated)

          say_schedule_by_hand(RECURRING)
        end

        # Inserts the tasks under a plain `production:` key, at the indentation
        # of its first task. An anchored or aliased key, or a file with no
        # production key, gets nothing.
        def with_recurring_entries(original)
          key = original.match(/^production:[ \t]*(?:#.*)?(\r?\n|\z)/)
          return unless key

          rest = original[key.end(0)..]
          indent = rest[/\A(?:[ \t]*(?:#.*)?\r?\n)*([ \t]+)\S/, 1] || '  '
          "#{original[0...key.end(0)]}#{"\n" if key[1].empty?}#{recurring_entries(indent)}#{rest}"
        end

        def recurring_entries(indent)
          tasks = SCHEDULE.map do |key, job, every, _cron|
            "#{indent}#{key}:\n#{indent * 2}class: #{job}\n#{indent * 2}schedule: #{every}\n"
          end
          "#{indent}# spree-bank_payments: expiry, reminders and polling\n#{tasks.join}"
        end

        def recurring_kept?(original, updated)
          before = load_yaml(original)
          after = load_yaml(updated)
          return false unless before.is_a?(Hash) && after.is_a?(Hash) && after['production'].is_a?(Hash)

          old_tasks = before['production'] || {}
          old_tasks.is_a?(Hash) &&
            after.except('production') == before.except('production') &&
            after['production'].slice(*old_tasks.keys) == old_tasks &&
            SCHEDULE.all? { |key, job, *| after['production'].dig(key, 'class') == job }
        end

        def schedule_in_sidekiq_cron
          path = SIDEKIQ_CRON_FILES.find { |file| schedule_file?(file) }
          unless path
            create_file SIDEKIQ_CRON_FILES.first, cron_entries(:hash)
            return say_cron_note(SIDEKIQ_CRON_FILES.first)
          end
          return if already_scheduled?(path)

          original = schedule_text(path)
          updated = with_cron_entries(original)
          return say_schedule_by_hand(path) unless updated && cron_kept?(original, updated)

          write_schedule(path, updated)
          say_cron_note(path)
        end

        # sidekiq-cron accepts a hash of jobs or a list of them. A file with
        # ERB in it cannot be checked before it is written.
        def with_cron_entries(original)
          return if original.include?('<%')

          existing = load_yaml(original)
          format = existing.is_a?(Array) ? :list : :hash
          return unless existing.nil? || existing.is_a?(Hash) || existing.is_a?(Array)

          separator = original.empty? || original.end_with?("\n") ? '' : "\n"
          "#{original}#{separator}#{"\n" unless original.strip.empty?}#{cron_entries(format)}"
        rescue Psych::Exception
          nil
        end

        def cron_entries(format)
          jobs = SCHEDULE.map do |key, job, _every, cron|
            fields = "cron: \"#{cron}\"\n  class: #{job}\n  queue: default\n"
            format == :list ? "- name: #{key}\n  #{fields}" : "#{key}:\n  #{fields}"
          end
          "# spree-bank_payments: expiry, reminders and polling\n#{jobs.join}"
        end

        def cron_kept?(original, updated)
          before = load_yaml(original)
          after = load_yaml(updated)
          ours = SCHEDULE.map(&:first)

          case before
          when Array
            after.is_a?(Array) && after.first(before.size) == before && (ours - after.filter_map { |job| job['name'] }).empty?
          when Hash, nil, false
            old_jobs = before || {}
            after.is_a?(Hash) && after.slice(*old_jobs.keys) == old_jobs && (ours - after.keys).empty?
          else
            false
          end
        end

        def say_cron_note(path)
          say_status :note, "sidekiq-cron loads #{path} when Sidekiq starts; if you load another file, move these entries there",
                     :yellow
        end

        def load_yaml(content)
          YAML.safe_load(content, aliases: true)
        rescue Psych::Exception
          :unreadable
        end

        def schedule_file?(path) = File.exist?(File.join(destination_root, path))
        def schedule_text(path) = File.read(File.join(destination_root, path))

        def write_schedule(path, content)
          create_file path, content, force: true
        end

        def already_scheduled?(path)
          return false unless schedule_text(path).include?('Spree::BankPayments::SendRemindersJob')

          say_status :skip, "#{path} already schedules the bank transfer jobs", :yellow
          true
        end

        # @param path [String, nil] the schedule file that could not be edited
        def say_schedule_by_hand(path = nil)
          reason = path ? "#{path} could not be edited safely; " : ''
          say_status :todo, "#{reason}schedule these jobs, or nothing expires and no reminder is sent:", :yellow
          SCHEDULE.each { |_key, job, _every, cron| say "  #{cron.ljust(14)} #{job}" }
          return if path

          say '  To write them for you, run again with --scheduler=solid_queue or --scheduler=sidekiq_cron.'
        end

        # `ask` returns "" in a non-interactive run (CI, scripted installs), and
        # "" is not "n", so the default stays "yes, migrate" -- matching the
        # previous unconditional behaviour.
        def run_migrations?
          return true if options[:auto_run_migrations]

          ask('Run the migrations now? [Yn]').to_s.strip.casecmp('n') != 0
        end
      end
    end
  end
end
