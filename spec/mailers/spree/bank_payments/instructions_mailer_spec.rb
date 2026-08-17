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
  let(:session) do
    create(:bank_transfer_payment_session, order: order, payment_method: payment_method)
  end

  describe '#instructions' do
    subject(:mail) { described_class.instructions(session.id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'renders the reference subject' do
      expect(mail.subject).to eq(Spree.t('bank_payments.reference'))
    end

    it 'includes the payment reference in the body' do
      expect(mail.body.encoded).to include(session.reference)
    end

    it 'includes every detail set, labelled, in the body' do
      expect(mail.body.encoded).to include('UK payments')
      expect(mail.body.encoded).to include('International')
      expect(mail.body.encoded).to include('04-00-75')
      expect(mail.body.encoded).to include('GB00REVO00000000000000')
    end
  end

  describe '#reminder' do
    subject(:mail) { described_class.reminder(session.id) }

    let(:days_remaining) { (session.expires_at.to_date - Date.current).to_i }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'renders a pay-within subject that matches the days remaining on the session' do
      expect(mail.subject).to eq(Spree.t('bank_payments.pay_within', days: days_remaining))
    end

    it 'states the same days-remaining figure in the subject and the body, so they cannot drift' do
      expect(mail.body.encoded).to include(Spree.t('bank_payments.pay_within', days: days_remaining))
    end

    it 'includes the payment reference in the body' do
      expect(mail.body.encoded).to include(session.reference)
    end

    it 'includes every detail set, labelled, in the body' do
      expect(mail.body.encoded).to include('UK payments')
      expect(mail.body.encoded).to include('International')
      expect(mail.body.encoded).to include('04-00-75')
      expect(mail.body.encoded).to include('GB00REVO00000000000000')
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
    # bank_account_id is recorded the way checkout records it.
    let(:quoted_session) { payment_method.create_payment_session(order: order) }

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
      body = described_class.instructions(quoted_session.id).body.encoded

      expect(body).to include('04-00-75')
      # Both: quoted-printable can soft-wrap the long IBAN, so the short
      # label is the assertion that cannot pass by accident.
      expect(body).not_to include('Replacement bank')
      expect(body).not_to include('GB99NEWACCOUNT0000000')
    end

    it 'is what #reminder renders after the offered account changes' do
      body = described_class.reminder(quoted_session.id).body.encoded

      expect(body).to include('04-00-75')
      # Both: quoted-printable can soft-wrap the long IBAN, so the short
      # label is the assertion that cannot pass by accident.
      expect(body).not_to include('Replacement bank')
      expect(body).not_to include('GB99NEWACCOUNT0000000')
    end

    it 'still renders coordinates in a reminder when the currency is no longer offered at all' do
      Spree::BankPayments::BankAccount.where(payment_method_id: payment_method.id).update_all(offered: false)

      body = described_class.reminder(quoted_session.id).body.encoded

      expect(body).to include('04-00-75')
      expect(body).to include('GB00REVO00000000000000')
    end
  end
end
