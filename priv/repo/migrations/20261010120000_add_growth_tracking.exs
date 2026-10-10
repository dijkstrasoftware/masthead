defmodule Masthead.Repo.Migrations.AddGrowthTracking do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :signup_method, :string, null: false, default: "email"
      add :signup_method_inferred, :boolean, null: false, default: false
      add :activated_at, :utc_datetime
      add :activated_via, :string
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :gclid_present, :boolean, null: false, default: false
      add :landing_path, :string
      add :referrer_domain, :string
      add :first_seen_at, :utc_datetime
    end

    create index(:users, [:inserted_at])

    alter table(:sites) do
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :initial_theme_id, references(:themes, on_delete: :nilify_all)
      add :theme_choice, :string
    end

    create index(:sites, [:created_by_id])

    alter table(:pages) do
      add :published_at, :utc_datetime
    end

    create table(:user_activity_days, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :date, :date, primary_key: true
    end

    create table(:license_events) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source, :string, null: false
      add :plan, :string
      add :status, :string
      add :amount_cents, :integer
      add :currency, :string
      add :expires_at, :utc_datetime
      add :occurred_at, :utc_datetime, null: false
    end

    create index(:license_events, [:site_id, :occurred_at])
  end
end
