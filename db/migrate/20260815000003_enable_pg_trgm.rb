class EnablePgTrgm < ActiveRecord::Migration[8.1]
  # PostgreSQL DDL is transactional. Without this, `CREATE EXTENSION` raising
  # insufficient_privilege aborts the surrounding transaction: the `rescue`
  # below runs and `say` prints, but the migrator's own INSERT into
  # schema_migrations then fails with PG::InFailedSqlTransaction and
  # `rails db:migrate` hard-fails. On any host whose role lacks CREATE on the
  # database -- standard on RDS, and exactly the case this rescue exists for
  # -- that blocked installation outright. Running outside a DDL transaction
  # means the failed CREATE EXTENSION autocommits on its own and poisons
  # nothing, so the rescue can genuinely degrade.
  disable_ddl_transaction!

  def up
    unless extension_available?
      say 'pg_trgm is not available on this server; payer name suggestions disabled'
      return
    end

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

  private

  # Cheap pre-check: on a server where the extension isn't even packaged
  # there is nothing to attempt, so don't emit a scary error line. The
  # privilege case still lands in the rescue -- pg_available_extensions says
  # nothing about whether *this* role may create it.
  def extension_available?
    connection.select_value(
      "SELECT 1 FROM pg_available_extensions WHERE name = 'pg_trgm'"
    ).present?
  rescue ActiveRecord::StatementInvalid
    true
  end
end
