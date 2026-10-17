defmodule Tackle.Web.Repo.Migrations.AddOwnershipAndAccess do
  @moduledoc """
  Ownership and access (docs/TACKLE_WEB_PLAN.md §7.12): installation owners,
  access grants, providers owned by users (a UUID key, and the old id as the
  per-owner `name`), and review defaults per user.

  Generated with `mix ash.codegen`, then rewritten to move existing rows:
  providers and the defaults row go to the oldest admin; installations go to
  the signed-in user whose login is the installation's account (a user
  account; only when exactly one user has that login, ignoring case),
  otherwise to the oldest admin. Deleting a user deletes their providers and
  defaults. It refuses to run when providers
  or defaults exist and nobody is an admin to own them.

  `down` restores the earlier schema. It keeps the most recently updated
  defaults row only, and fails when two owners have providers of the same
  name.
  """

  use Ecto.Migration

  @oldest_admin "(SELECT id FROM users WHERE admin ORDER BY inserted_at, id LIMIT 1)"

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM users WHERE admin)
         AND (EXISTS (SELECT 1 FROM providers) OR EXISTS (SELECT 1 FROM review_defaults)) THEN
        RAISE EXCEPTION 'tackle_web: providers or review defaults exist, but no admin to own them; '
          'make a user an admin first (Tackle.Web.Release.set_admin/2)';
      END IF;
    END $$;
    """)

    create table(:accesses, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :forge_user_id, :text, null: false
      add :login, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :installation_id,
          references(:installations,
            column: :id,
            name: "accesses_installation_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :repository_id,
          references(:repositories,
            column: :id,
            name: "accesses_repository_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          )

      add :granted_by_id,
          references(:users,
            column: :id,
            name: "accesses_granted_by_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    create unique_index(:accesses, [:installation_id, :repository_id, :forge_user_id],
             name: "accesses_unique_grant_index",
             nulls_distinct: false
           )

    alter table(:installations) do
      add :owner_external_id, :text
      add :owner_login, :text
    end

    # GitHub logins are case-insensitive, and a renamed account can leave a
    # stale login behind: only a login that names exactly one user counts.
    execute("""
    UPDATE installations AS i
    SET owner_external_id = u.external_id, owner_login = u.login
    FROM users AS u
    WHERE u.forge = i.forge AND lower(u.login) = lower(i.account)
      AND (SELECT count(*) FROM users AS same
           WHERE same.forge = i.forge AND lower(same.login) = lower(i.account)) = 1
    """)

    execute("""
    UPDATE installations AS i
    SET owner_external_id = u.external_id, owner_login = u.login
    FROM users AS u
    WHERE i.owner_external_id IS NULL AND u.id = #{@oldest_admin}
    """)

    # Providers: the old text id becomes the per-owner name.
    rename table(:providers), :id, to: :name
    drop constraint(:providers, "providers_pkey")

    alter table(:providers) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")

      add :owner_id,
          references(:users,
            column: :id,
            name: "providers_owner_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          )
    end

    execute("ALTER TABLE providers ADD PRIMARY KEY (id)")
    execute("UPDATE providers SET owner_id = #{@oldest_admin}")

    alter table(:providers) do
      modify :owner_id, :uuid, null: false
    end

    create unique_index(:providers, [:owner_id, :name], name: "providers_unique_name_index")

    # Review defaults: one row per user instead of one for the server.
    drop constraint(:review_defaults, :review_defaults_singleton)
    drop constraint(:review_defaults, "review_defaults_pkey")

    alter table(:review_defaults) do
      remove :id

      add :user_id,
          references(:users,
            column: :id,
            name: "review_defaults_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          )
    end

    execute("UPDATE review_defaults SET user_id = #{@oldest_admin}")

    alter table(:review_defaults) do
      modify :user_id, :uuid, null: false
    end

    execute("ALTER TABLE review_defaults ADD PRIMARY KEY (user_id)")
  end

  def down do
    execute("""
    DELETE FROM review_defaults
    WHERE user_id <> (SELECT user_id FROM review_defaults ORDER BY updated_at DESC LIMIT 1)
    """)

    drop constraint(:review_defaults, "review_defaults_pkey")

    alter table(:review_defaults) do
      remove :user_id
      add :id, :bigint, null: false, default: 1, primary_key: true
    end

    create constraint(:review_defaults, :review_defaults_singleton, check: "id = 1")

    drop_if_exists unique_index(:providers, [:owner_id, :name],
                     name: "providers_unique_name_index"
                   )

    drop constraint(:providers, "providers_pkey")

    alter table(:providers) do
      remove :owner_id
      remove :id
    end

    rename table(:providers), :name, to: :id
    execute("ALTER TABLE providers ADD PRIMARY KEY (id)")

    alter table(:installations) do
      remove :owner_login
      remove :owner_external_id
    end

    drop table(:accesses)
  end
end
