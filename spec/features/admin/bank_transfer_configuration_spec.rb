require 'spec_helper'

RSpec.feature 'Bank transfer configuration guide', type: :feature do
  stub_authorization!

  let!(:payment_method) { create(:bank_transfer_gateway) }

  scenario 'shows the webhook URL and reconciler health' do
    visit spree.edit_admin_payment_method_path(payment_method)

    expect(page).to have_content('/api/v3/webhooks/payments/')
    expect(page).to have_content('Reconciler')
  end

  # This is the screen an admin uses to switch the reconciler back to 'manual'
  # after a provider gem is uninstalled. The guide partial calls
  # #reconciler_healthy?, so if that raises for an unregistered key the one
  # recovery route is locked -- the record can be saved but the form to save it
  # from cannot be opened.
  scenario 'still opens when the named provider gem is no longer installed' do
    payment_method.preferred_reconciler = 'a_provider_gem_that_was_uninstalled'
    payment_method.save!(validate: false)

    visit spree.edit_admin_payment_method_path(payment_method)

    # Asserted on the webhook URL, not the word "Reconciler": Spree renders a
    # humanized label for the `preferred_reconciler` preference field, so
    # "Reconciler" appears on this page whether or not the guide partial -- the
    # thing that calls #reconciler_healthy? -- rendered at all.
    expect(page).to have_content('/api/v3/webhooks/payments/')
    expect(page).to have_content('Unhealthy')
  end
end
