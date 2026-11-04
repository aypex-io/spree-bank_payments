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

        class_option :scheduler,
                     type: :string,
                     enum: %w[solid_queue sidekiq_cron none],
                     desc: "Where to schedule the jobs. Default: the app's Active Job adapter " \
                           '(Solid Queue, or Sidekiq with sidekiq-cron)'

        def copy_migrations
          # Scoped to this engine only: sets ENV["FROM"] = "spree_bank_payments" before
          # delegating to railties:install:migrations, so migrations pending on other
          # railties (e.g. action_mailbox, acts_as_taggable_on) are never touched.
          rake 'spree_bank_payments:install:migrations'
        end

        def run_migrations
          if run_migrations?
            rake 'db:migrate'
          else
            say_status :skip, 'db:migrate — remember to run it before using the gem', :yellow
          end
        end

        # Writes the jobs into config/recurring.yml (Solid Queue, what a stock
        # Spree 6 store runs) or config/schedule.yml (sidekiq-cron), leaving
        # the entries already there alone. Running it again adds nothing.
        def add_schedule
          case scheduler
          when 'solid_queue' then schedule_in_solid_queue
          when 'sidekiq_cron' then schedule_in_sidekiq_cron
          else say_schedule_by_hand
          end
        end

        private

        def scheduler
          options[:scheduler] || detected_scheduler
        end

        def detected_scheduler
          case Rails.application.config.active_job.queue_adapter.to_s
          when 'solid_queue' then 'solid_queue'
          when 'sidekiq' then sidekiq_cron_bundled? ? 'sidekiq_cron' : 'none'
          else 'none'
          end
        end

        def sidekiq_cron_bundled?
          lockfile = File.join(destination_root, 'Gemfile.lock')
          File.exist?(lockfile) && File.read(lockfile).match?(/^    sidekiq-cron /)
        end

        def schedule_in_solid_queue
          path = 'config/recurring.yml'
          return if already_scheduled?(path)

          entries = SCHEDULE.map do |key, job, every, _cron|
            "  #{key}:\n    class: #{job}\n    schedule: #{every}\n"
          end.join
          entries = "  # spree-bank_payments: expiry, reminders and polling\n#{entries}"

          if !File.exist?(File.join(destination_root, path))
            create_file path, "production:\n#{entries}"
          elsif File.read(File.join(destination_root, path)).match?(/^production:\s*$/)
            inject_into_file path, entries, after: /^production:\s*\n/
          else
            append_to_file path, "\nproduction:\n#{entries}"
          end
        end

        # sidekiq-cron loads config/schedule.yml when Sidekiq starts.
        def schedule_in_sidekiq_cron
          path = 'config/schedule.yml'
          return if already_scheduled?(path)

          entries = SCHEDULE.map do |key, job, _every, cron|
            "#{key}:\n  cron: \"#{cron}\"\n  class: #{job}\n  queue: default\n"
          end.join
          entries = "# spree-bank_payments: expiry, reminders and polling\n#{entries}"

          if File.exist?(File.join(destination_root, path))
            append_to_file path, "\n#{entries}"
          else
            create_file path, entries
          end
          say_status :note, "sidekiq-cron loads #{path}; if you load another file, move these entries there", :yellow
        end

        def already_scheduled?(path)
          full = File.join(destination_root, path)
          return false unless File.exist?(full) && File.read(full).include?('Spree::BankPayments::SendRemindersJob')

          say_status :skip, "#{path} already schedules the bank transfer jobs", :yellow
          true
        end

        def say_schedule_by_hand
          say_status :todo, 'schedule these jobs in your scheduler, or nothing expires and no reminder is sent:', :yellow
          SCHEDULE.each { |_key, job, _every, cron| say "  #{cron.ljust(14)} #{job}" }
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
