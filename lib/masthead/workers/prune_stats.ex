defmodule Masthead.Workers.PruneStats do
  @moduledoc """
  Daily sweep (Oban cron) that drops view statistics past retention and the
  previous days' visitor hashes, which are only needed to dedupe today.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Masthead.Stats.prune()
end
