defmodule Masthead.Features do
  @moduledoc """
  Optional features, switched on by naming them in the comma-separated
  `FEATURES` env var (e.g. `FEATURES=homepage`). Anything not listed is off,
  so a fresh self-hosted install gets none of them.

  * `homepage` — the marketing homepage at `/`. Without it, `/` sends
    visitors straight to the login screen.
  """

  def enabled?(feature) when is_binary(feature) do
    feature in (System.get_env("FEATURES", "")
                |> String.split(",", trim: true)
                |> Enum.map(&String.trim/1))
  end
end
