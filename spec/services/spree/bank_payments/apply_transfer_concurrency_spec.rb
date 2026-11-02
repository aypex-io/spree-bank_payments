require 'spec_helper'

# Two staff apply one transfer to two different orders at the same moment.
# Each request holds its own order's lock, so only a lock on the transfer
# itself stops the second from capturing as well.
#
# Proving that needs committed rows on separate connections, so this runs
# outside the usual test transaction: every database call happens on a
# thread's own connection, and the tables are emptied the same way. It is its
# own top-level group, without Spree's shared test store, because emptying the
# tables removes that store; the next group's before(:all) creates it again.
RSpec.describe Spree::BankPayments::ApplyTransfer, without_global_store: true do
  self.use_transactional_tests = false

  def on_own_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  # Deletion, not truncation: TRUNCATE would wait on any read lock the
  # surrounding DatabaseCleaner transaction holds on the main connection.
  after { on_own_connection { DatabaseCleaner.clean_with(:deletion) }.join }

  it 'captures one payment and refuses the other' do
    first, second, transfer_id = on_own_connection do
      Spree::Store.find_by(default: true) || create(:store, default: true, default_currency: 'USD')
      gateway = create(:bank_transfer_gateway)
      sessions = Array.new(2) do
        place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway).last
      end
      transfer = create(:bank_transfer_incoming_transfer,
                        payment_method_id: gateway.id, amount: sessions.first.amount,
                        currency: sessions.first.currency, reference_raw: 'MISTYPED')
      [*sessions, transfer.id]
    end.value

    # Hold the first request inside its capture, after it has read the
    # transfer, until the second request has had its chance.
    in_capture = Queue.new
    release = Queue.new
    allow(Spree.payment_capture_workflow).to receive(:call).and_wrap_original do |original, **kwargs|
      if Thread.current[:hold_capture]
        in_capture << true
        release.pop
      end
      original.call(**kwargs)
    end

    apply = lambda do |payment_session, hold:|
      on_own_connection do
        Thread.current[:hold_capture] = hold
        transfer = Spree::BankPayments::IncomingTransfer.find(transfer_id)
        described_class.call(transfer: transfer, payment_session: payment_session)
        :applied
      rescue described_class::Refused => e
        e.class
      end
    end

    winner = apply.call(first, hold: true)
    in_capture.pop
    loser = apply.call(second, hold: false)
    loser.join(1)
    release << true
    [winner, loser].each(&:join)

    paid_orders = on_own_connection do
      Spree::Order.where(id: [first.order_id, second.order_id], payment_status: 'paid').count
    end.value
    expect([winner.value, loser.value, paid_orders]).to eq([:applied, described_class::AlreadyApplied, 1])
  end
end
