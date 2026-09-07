defmodule Masthead.Repo.Migrations.AddLicenseToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :license_plan, :string
      add :license_status, :string
      add :license_expires_at, :utc_datetime
      add :payment_customer_id, :string
      add :payment_subscription_id, :string
    end

    create unique_index(:sites, [:payment_subscription_id])
  end
end
