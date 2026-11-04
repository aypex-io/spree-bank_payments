require 'spec_helper'

RSpec.describe Spree::BankPayments::InstructionsMailer, type: :mailer do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let!(:bank_account) do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
  end
  # Pinned to GBP: the session factory below defaults to GBP too, and a USD
  # order could never actually carry this payment method now that
  # Gateway#available_for_order? requires an offered account matching the
  # order's currency. Leaving this at the USD factory default made the
  # fixture look currency-agnostic when it silently wasn't.
  let(:order) { create(:completed_order_with_totals, currency: 'GBP') }
  let(:store) { order.store }
  # 03:30 UTC on the 12th is 22:30 on the 11th in New York: a deadline
  # rendered in UTC, or as a count of days, would tell a buyer there the
  # wrong day.
  let(:session) do
    create(:bank_transfer_payment_session, order: order, payment_method: payment_method).tap do |session|
      session.update_columns(expires_at: Time.utc(2026, 11, 12, 3, 30))
    end
  end

  def html(mail) = mail.html_part.decoded
  def text(mail) = mail.text_part.decoded

  describe '#instructions' do
    before { store.update!(preferred_timezone: 'America/New_York') }

    subject(:mail) { described_class.instructions(session.prefixed_id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'names the store and the order in the subject' do
      expect(mail.subject).to eq("#{store.name} Bank transfer details for order ##{order.number}")
    end

    it 'names the order in the body' do
      expect(html(mail)).to include("##{order.number}")
    end

    it "gives the deadline in the store's time zone" do
      expect(html(mail)).to include('11 November 2026, 22:30 EST')
    end

    it 'says what happens if the transfer does not arrive' do
      expect(html(mail)).to include("If we don’t receive it by then, we’ll cancel the order.")
    end

    it 'includes the payment reference and the amount in the body' do
      expect(html(mail)).to include(session.reference, session.money.to_s)
    end

    it 'includes every detail set, labelled, in the body' do
      expect(html(mail)).to include('UK payments', 'International', '04-00-75', 'GB00REVO00000000000000')
    end

    it 'has a plain-text part with the reference, the deadline and the bank details' do
      expect(text(mail)).to include(session.reference, '11 November 2026, 22:30 EST', '04-00-75')
    end
  end

  describe '#reminder' do
    before { store.update!(preferred_timezone: 'America/New_York') }

    subject(:mail) { described_class.reminder(session.prefixed_id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    # A count of days reads "within 1 days", and is a different number
    # depending on whose midnight it is counted from.
    it 'names the order and the deadline date in the subject' do
      expect(mail.subject).to eq("#{store.name} Reminder: pay for order ##{order.number} by 11 November 2026")
    end

    it "gives the deadline in the store's time zone in the body" do
      expect(html(mail)).to include('11 November 2026, 22:30 EST')
    end

    it 'allows for a transfer already on its way' do
      expect(html(mail)).to include('a transfer can take a few days to arrive')
    end

    it 'includes the payment reference in the body' do
      expect(html(mail)).to include(session.reference)
    end

    it 'includes every detail set, labelled, in the body' do
      expect(html(mail)).to include('UK payments', 'International', '04-00-75', 'GB00REVO00000000000000')
    end

    it 'has a plain-text part' do
      expect(text(mail)).to include(session.reference, '04-00-75')
    end
  end

  describe '#expired' do
    before { store.update!(preferred_timezone: 'America/New_York') }

    subject(:mail) { described_class.expired(session.prefixed_id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'says in the subject that the order was cancelled, and why' do
      expect(mail.subject).to eq("#{store.name} Order ##{order.number} cancelled: bank transfer not received")
    end

    it 'names the order, the amount and the deadline that passed' do
      expect(html(mail)).to include("##{order.number}", session.money.to_s, '11 November 2026, 22:30 EST')
    end

    it 'tells a buyer who already paid what to do' do
      expect(html(mail)).to include("If you’ve already sent the transfer, reply to this email")
    end

    # The order is cancelled: bank details would invite a payment nobody
    # can match.
    it 'leaves out the bank details' do
      expect(html(mail)).not_to include('04-00-75')
    end

    it 'has a plain-text part' do
      expect(text(mail)).to include("##{order.number}", '11 November 2026, 22:30 EST')
    end
  end

  # C2. Both mailer actions read the account the session was quoted against,
  # not the currently offered one. The reminder is the dangerous case: it is
  # sent days after checkout, which is exactly the window in which an admin
  # switches accounts. Quoting the new account's coordinates against a
  # reference generated for the old one sends the customer's money to the
  # wrong place; un-offering the currency entirely used to render a reminder
  # with an amount, a deadline, and no coordinates at all.
  describe 'the account a session was quoted against' do
    # Goes through the gateway rather than the session factory so
    # bank_account_id is recorded the way checkout records it, then moves
    # onto the order the way Spree's cart completion repoints it.
    let(:quoted_session) do
      cart = create(:cart_with_line_items, currency: 'GBP', store: order.store)
      payment_method.create_payment_session(order: cart).tap do |session|
        session.update_columns(cart_id: nil, order_id: order.id)
      end
    end

    before do
      quoted_session
      bank_account.update!(offered: false)
      create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true,
             details: [{ 'label' => 'Replacement bank',
                         'fields' => [{ 'label' => 'IBAN', 'value' => 'GB99NEWACCOUNT0000000' }] }])
    end

    it 'records the account on the session at checkout' do
      expect(quoted_session.bank_account).to eq(bank_account)
    end

    it 'is what #instructions renders after the offered account changes' do
      body = described_class.instructions(quoted_session.prefixed_id).body.encoded

      expect(body).to include('04-00-75')
      # Both: quoted-printable can soft-wrap the long IBAN, so the short
      # label is the assertion that cannot pass by accident.
      expect(body).not_to include('Replacement bank')
      expect(body).not_to include('GB99NEWACCOUNT0000000')
    end

    it 'is what #reminder renders after the offered account changes' do
      body = described_class.reminder(quoted_session.prefixed_id).body.encoded

      expect(body).to include('04-00-75')
      # Both: quoted-printable can soft-wrap the long IBAN, so the short
      # label is the assertion that cannot pass by accident.
      expect(body).not_to include('Replacement bank')
      expect(body).not_to include('GB99NEWACCOUNT0000000')
    end

    it 'still renders coordinates in a reminder when the currency is no longer offered at all' do
      Spree::BankPayments::BankAccount.where(payment_method_id: payment_method.id).update_all(offered: false)

      body = described_class.reminder(quoted_session.prefixed_id).body.encoded

      expect(body).to include('04-00-75')
      expect(body).to include('GB00REVO00000000000000')
    end
  end

  describe 'an order placed through checkout' do
    let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
    let(:placed) { place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway) }

    it "emails the instructions to the order's address" do
      order, session = placed

      expect(described_class.instructions(session.prefixed_id).to).to eq([order.email])
    end

    it 'quotes the discounted amount' do
      _, session = placed

      expect(described_class.instructions(session.prefixed_id).body.encoded).to include('97.00')
    end
  end
end
