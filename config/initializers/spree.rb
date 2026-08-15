Rails.application.config.after_initialize do
  # Payment method registration is added by Task 3, alongside the Gateway class
  # it references. Registering it here would forward-reference a constant that
  # does not exist yet and break dummy app boot.
end
