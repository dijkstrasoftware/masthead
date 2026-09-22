defmodule Masthead.Repo.Migrations.CreateSiteStats do
  use Ecto.Migration

  def change do
    create table(:site_view_days, primary_key: false) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :views, :integer, null: false, default: 0
      add :visitors, :integer, null: false, default: 0
    end

    create unique_index(:site_view_days, [:site_id, :date])

    create table(:page_view_days, primary_key: false) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :date, :date, null: false
      add :views, :integer, null: false, default: 0
      add :visitors, :integer, null: false, default: 0
    end

    create unique_index(:page_view_days, [:site_id, :path, :date])
    create index(:page_view_days, [:site_id, :date])

    create table(:view_visitors, primary_key: false) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :visitor_hash, :binary, null: false
      add :path, :text, null: false
    end

    create unique_index(:view_visitors, [:site_id, :date, :visitor_hash, :path])
  end
end
