require 'spec_helper'
require 'generators/spree/bank_payments/install/install_generator'

# Nothing expires and no reminder is sent unless the three jobs run on a
# schedule, so installing the gem writes them into the host's scheduler.
RSpec.describe Spree::BankPayments::Generators::InstallGenerator do
  let(:root) { Pathname(Dir.mktmpdir) }

  after { FileUtils.rm_rf(root) }

  def add_schedule(scheduler)
    described_class.new([], { scheduler: scheduler }, destination_root: root.to_s).add_schedule
  end

  def write(path, content)
    root.join(path).dirname.mkpath
    root.join(path).write(content)
  end

  def yaml(path) = YAML.safe_load(root.join(path).read)

  context 'with Solid Queue, as a stock Spree 6 store runs' do
    before { write('config/recurring.yml', "production:\n  expire_stock_reservations:\n    class: Spree::StockReservations::ExpireJob\n    schedule: every minute\n") }

    it 'adds the three jobs to production' do
      quietly { add_schedule('solid_queue') }

      expect(yaml('config/recurring.yml')['production'].values.pluck('class')).to include(
        'Spree::BankPayments::ExpireSessionsJob', 'Spree::BankPayments::SendRemindersJob',
        'Spree::BankPayments::PollJob'
      )
    end

    it "keeps the store's own tasks" do
      quietly { add_schedule('solid_queue') }

      expect(yaml('config/recurring.yml')['production']).to include('expire_stock_reservations')
    end

    it 'sends reminders once a day' do
      quietly { add_schedule('solid_queue') }

      expect(yaml('config/recurring.yml').dig('production', 'bank_payments_send_reminders', 'schedule')).
        to eq('every day at 9am')
    end

    it 'adds nothing twice' do
      quietly { 2.times { add_schedule('solid_queue') } }

      expect(root.join('config/recurring.yml').read.scan('SendRemindersJob').size).to eq(1)
    end
  end

  # Real files are not all the starter's. Each of these, edited naively, hides
  # or drops the store's own production tasks; YAML keeps the last of two
  # duplicate keys, and Solid Queue ignores keys it doesn't know.
  context 'with a recurring.yml shaped otherwise' do
    def production_tasks = yaml('config/recurring.yml')['production']

    it 'adds to a production key with a comment after it' do
      write('config/recurring.yml', "production: # every environment\n  expire_stock_reservations:\n    class: Spree::StockReservations::ExpireJob\n    schedule: every minute\n")

      quietly { add_schedule('solid_queue') }

      expect(production_tasks.keys).to include('expire_stock_reservations', 'bank_payments_send_reminders')
    end

    it 'matches four-space indentation' do
      write('config/recurring.yml', "production:\n    expire_stock_reservations:\n        class: Spree::StockReservations::ExpireJob\n        schedule: every minute\n")

      quietly { add_schedule('solid_queue') }

      expect(production_tasks.transform_values { |task| task['class'] }).to include(
        'expire_stock_reservations' => 'Spree::StockReservations::ExpireJob',
        'bank_payments_send_reminders' => 'Spree::BankPayments::SendRemindersJob'
      )
    end

    it 'adds to a production key on the last line with no newline' do
      write('config/recurring.yml', "development:\n  foo:\n    class: FooJob\n    schedule: every minute\nproduction:")

      quietly { add_schedule('solid_queue') }

      expect(production_tasks.keys).to include('bank_payments_send_reminders')
    end

    {
      'a production key that is an anchor' => "production: &production\n  expire_stock_reservations:\n    class: Spree::StockReservations::ExpireJob\n    schedule: every minute\n",
      'a production key that is an alias' => "default: &default\n  expire_stock_reservations:\n    class: Spree::StockReservations::ExpireJob\n    schedule: every minute\nproduction: *default\n",
      'tasks with no environment keys' => "expire_stock_reservations:\n  class: Spree::StockReservations::ExpireJob\n  schedule: every minute\n"
    }.each do |shape, content|
      it "leaves #{shape} alone and says what to add" do
        write('config/recurring.yml', content)

        expect { add_schedule('solid_queue') }.to output(/SendRemindersJob/).to_stdout
        expect(root.join('config/recurring.yml').read).to eq(content)
      end
    end
  end

  context 'with sidekiq-cron' do
    it 'writes the jobs to its schedule file' do
      quietly { add_schedule('sidekiq_cron') }

      expect(yaml('config/schedule.yml')['bank_payments_send_reminders']).
        to eq('cron' => '0 9 * * *', 'class' => 'Spree::BankPayments::SendRemindersJob', 'queue' => 'default')
    end

    it 'keeps the jobs already there' do
      write('config/schedule.yml', "nightly_report:\n  cron: '0 2 * * *'\n  class: NightlyReportJob\n")

      quietly { add_schedule('sidekiq_cron') }

      expect(yaml('config/schedule.yml').keys).to include('nightly_report', 'bank_payments_expire_sessions')
    end

    it 'adds nothing twice' do
      quietly { 2.times { add_schedule('sidekiq_cron') } }

      expect(root.join('config/schedule.yml').read.scan('SendRemindersJob').size).to eq(1)
    end
  end

  context 'with a sidekiq-cron schedule shaped otherwise' do
    it 'adds list entries to a schedule written as a list' do
      write('config/schedule.yml', "- name: nightly_report\n  cron: '0 2 * * *'\n  class: NightlyReportJob\n")

      quietly { add_schedule('sidekiq_cron') }

      expect(yaml('config/schedule.yml').pluck('name')).to include('nightly_report', 'bank_payments_send_reminders')
    end

    # sidekiq-cron reads schedule.yml when it exists, and then deletes the
    # jobs it had loaded from schedule.yaml.
    it 'writes to schedule.yaml when that is the file the app has' do
      write('config/schedule.yaml', "nightly_report:\n  cron: '0 2 * * *'\n  class: NightlyReportJob\n")

      quietly { add_schedule('sidekiq_cron') }

      expect([root.join('config/schedule.yml').exist?, yaml('config/schedule.yaml').keys]).
        to eq([false, %w[nightly_report bank_payments_expire_sessions bank_payments_send_reminders bank_payments_poll]])
    end

    it 'leaves a schedule with ERB in it alone and says what to add' do
      content = "nightly_report:\n  cron: '<%= ENV.fetch(\"REPORT_CRON\") %>'\n  class: NightlyReportJob\n"
      write('config/schedule.yml', content)

      expect { add_schedule('sidekiq_cron') }.to output(/SendRemindersJob/).to_stdout
      expect(root.join('config/schedule.yml').read).to eq(content)
    end
  end

  # Run again to schedule the jobs on an existing install, it need not touch
  # migrations: an app that pruned old ones would get them back.
  it 'copies and runs no migrations with --skip-migrations' do
    generator = described_class.new([], { skip_migrations: true }, destination_root: root.to_s)
    allow(generator).to receive(:rake)

    quietly do
      generator.copy_migrations
      generator.run_migrations
    end

    expect(generator).not_to have_received(:rake)
  end

  context 'with no scheduler it knows' do
    it 'writes nothing' do
      quietly { add_schedule('none') }

      expect(root.join('config').exist?).to be(false)
    end
  end

  describe 'choosing the scheduler from the app' do
    def add_schedule_detected
      described_class.new([], {}, destination_root: root.to_s).add_schedule
    end

    it 'uses Solid Queue when Active Job runs on it' do
      allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:solid_queue)

      quietly { add_schedule_detected }

      expect(root.join('config/recurring.yml')).to exist
    end

    # A Rails 8 app sets Solid Queue in production.rb only, and the generator
    # runs in development.
    it 'uses Solid Queue when it is bundled and the app has a recurring.yml' do
      allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:async)
      write('Gemfile.lock', "GEM\n  specs:\n    solid_queue (1.2.4)\n")
      write('config/recurring.yml', "production:\n  foo:\n    class: FooJob\n    schedule: every minute\n")

      quietly { add_schedule_detected }

      expect(yaml('config/recurring.yml')['production'].keys).to include('bank_payments_send_reminders')
    end

    # Spree's test-app task runs the generator with no application loaded.
    it 'lists the jobs when no Rails application is loaded' do
      allow(Rails).to receive(:application).and_return(nil)

      expect { add_schedule_detected }.to output(/SendRemindersJob/).to_stdout
    end

    it 'names --scheduler when it cannot tell' do
      allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:async)

      expect { add_schedule_detected }.to output(/--scheduler/).to_stdout
    end

    it 'uses sidekiq-cron when Active Job runs on Sidekiq and sidekiq-cron is bundled' do
      allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:sidekiq)
      write('Gemfile.lock', "GEM\n  specs:\n    sidekiq-cron (2.3.0)\n")

      quietly { add_schedule_detected }

      expect(root.join('config/schedule.yml')).to exist
    end
  end

  def quietly(&)
    expect(&).to output.to_stdout
  end
end
