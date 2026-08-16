module SpreeBankPayments
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc 'Copies SpreeBankPayments migrations into the host application and runs them.'

      class_option :auto_run_migrations,
                   type: :boolean,
                   default: false,
                   desc: 'Run the copied migrations immediately instead of asking'

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

      private

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
