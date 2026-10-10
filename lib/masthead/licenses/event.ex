defmodule Masthead.Licenses.Event do
  @moduledoc "One change in a site's license state. Append-only history for the growth dashboard."
  use Ecto.Schema

  schema "license_events" do
    belongs_to :site, Masthead.Sites.Site
    field :kind, :string
    field :source, :string
    field :plan, :string
    field :status, :string
    field :amount_cents, :integer
    field :currency, :string
    field :expires_at, :utc_datetime
    field :occurred_at, :utc_datetime
  end
end
