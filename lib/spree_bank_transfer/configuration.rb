module SpreeBankTransfer
  class Configuration < Spree::Preferences::Configuration
    preference :disable_default_mailer, :boolean, default: false
  end
end
