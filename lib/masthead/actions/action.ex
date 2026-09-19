defmodule Masthead.Actions.Action do
  @moduledoc """
  A one-off, site-scoped task ("action") surfaced to the site owner in the
  admin checklist. Each action is unique per `(site_id, key)`; the `key`
  identifies its type (see `Masthead.Actions.Definitions`).

  Fields:

    * `key`      — stable identifier of the action type, unique per site
    * `status`   — `"pending"`, `"completed"`, or `"dismissed"`
    * `message`  — the message shown to the user
    * `priority` — higher numbers surface first
    * `path`     — optional admin path the action's button links to
    * `reminded_at` — set when a one-off reminder email was sent (never re-sent)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending completed dismissed)

  schema "actions" do
    field :key, :string
    field :status, :string, default: "pending"
    # Custom (admin-authored) actions store their own title; predefined ones
    # leave this nil and derive the title from `key`.
    field :title, :string
    field :message, :string
    field :priority, :integer, default: 0
    field :path, :string
    field :reminded_at, :utc_datetime

    belongs_to :site, Masthead.Sites.Site

    timestamps(type: :utc_datetime)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [:key, :status, :title, :message, :priority, :path, :site_id])
    |> validate_required([:key, :status, :site_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:path, ~r{\A(/|https?://)},
      message: "must start with /, http:// or https://"
    )
    |> assoc_constraint(:site)
    |> unique_constraint([:site_id, :key], name: :actions_site_id_key_index)
  end
end
