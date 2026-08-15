module AypexBankTransfer
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc 'Copies AypexBankTransfer migrations into the host application and runs them.'

      def copy_migrations
        # Scoped to this engine only: sets ENV["FROM"] = "aypex_bank_transfer" before
        # delegating to railties:install:migrations, so migrations pending on other
        # railties (e.g. action_mailbox, acts_as_taggable_on) are never touched.
        rake 'aypex_bank_transfer:install:migrations'
      end

      def run_migrations
        rake 'db:migrate'
      end
    end
  end
end
