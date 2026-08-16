class EnablePgTrgm < ActiveRecord::Migration[8.1]
  def up
    enable_extension 'pg_trgm'
  rescue ActiveRecord::StatementInvalid => e
    # Suggestions degrade to amount-only matching rather than blocking install
    # on databases where the role cannot create extensions.
    say "Could not enable pg_trgm (#{e.message}); payer name suggestions disabled"
  end

  def down
    disable_extension 'pg_trgm'
  rescue ActiveRecord::StatementInvalid
    nil
  end
end
