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
