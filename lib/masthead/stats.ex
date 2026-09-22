defmodule Masthead.Stats do
  @moduledoc """
  Server-side view statistics per site: daily views and daily unique visitors,
  for the whole site and per path. Visitors are identified by an opaque daily
  hash the caller computes; no raw IP or user agent is ever stored.

  `view_visitors` only exists to dedupe today's visitors and is pruned daily;
  the `*_view_days` aggregates are kept for `@retention_days`.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Masthead.Repo

  @retention_days 365

  @doc "Records one view of `path` on `site_id` by `visitor_hash`."
  def record_view(site_id, path, visitor_hash, date \\ Date.utc_today()) do
    row = %{site_id: site_id, date: date, visitor_hash: visitor_hash, path: path}

    Multi.new()
    |> Multi.run(:path_new?, &insert_visitor(&1, &2, row))
    |> Multi.run(:site_new?, &site_new?(&1, &2, row))
    |> Multi.run(:site_day, &bump_site_day(&1, &2, row))
    |> Multi.run(:page_day, &bump_page_day(&1, &2, row))
    |> Repo.transaction()
  end

  defp insert_visitor(repo, _changes, row) do
    {inserted, _} = repo.insert_all("view_visitors", [row], on_conflict: :nothing)
    {:ok, inserted == 1}
  end

  defp site_new?(_repo, %{path_new?: false}, _row), do: {:ok, false}

  defp site_new?(repo, _changes, row) do
    count =
      repo.aggregate(
        from(v in "view_visitors",
          where:
            v.site_id == ^row.site_id and v.date == ^row.date and
              v.visitor_hash == ^row.visitor_hash
        ),
        :count
      )

    {:ok, count == 1}
  end

  defp bump_site_day(repo, %{site_new?: new?}, row) do
    bump(repo, "site_view_days", Map.take(row, [:site_id, :date]), new?)
  end

  defp bump_page_day(repo, %{path_new?: new?}, row) do
    bump(repo, "page_view_days", Map.take(row, [:site_id, :path, :date]), new?)
  end

  defp bump(repo, table, key, new?) do
    visitors = if new?, do: 1, else: 0

    {count, _} =
      repo.insert_all(table, [Map.merge(key, %{views: 1, visitors: visitors})],
        on_conflict: [inc: [views: 1, visitors: visitors]],
        conflict_target: Map.keys(key)
      )

    {:ok, count}
  end

  @doc """
  One `%{date, views, visitors}` per day of `range`, zero-filled; the whole
  site, or only `path` when given.
  """
  def daily(site_id, %Date.Range{} = range, path \\ nil) do
    counts =
      site_id
      |> days_query(range, path)
      |> select([d], {d.date, %{views: d.views, visitors: d.visitors}})
      |> Repo.all()
      |> Map.new()

    Enum.map(range, &day_counts(&1, counts))
  end

  defp day_counts(date, counts) do
    Map.merge(%{date: date, views: 0, visitors: 0}, Map.get(counts, date, %{}))
  end

  @doc "Summed `%{views, visitors}` for the whole site over `range`."
  def totals(site_id, %Date.Range{} = range) do
    site_id
    |> days_query(range, nil)
    |> select([d], %{views: coalesce(sum(d.views), 0), visitors: coalesce(sum(d.visitors), 0)})
    |> Repo.one()
  end

  @doc "Paths viewed over `range` with summed views and visitors, most viewed first."
  def top_paths(site_id, %Date.Range{} = range) do
    site_id
    |> days_query(range, :all_paths)
    |> group_by([d], d.path)
    |> select([d], %{path: d.path, views: sum(d.views), visitors: sum(d.visitors)})
    |> order_by([d], desc: sum(d.views), asc: d.path)
    |> limit(100)
    |> Repo.all()
  end

  defp days_query(site_id, range, nil), do: in_range("site_view_days", site_id, range)
  defp days_query(site_id, range, :all_paths), do: in_range("page_view_days", site_id, range)

  defp days_query(site_id, range, path) do
    where(in_range("page_view_days", site_id, range), [d], d.path == ^path)
  end

  defp in_range(table, site_id, range) do
    from d in table,
      where: d.site_id == ^site_id and d.date >= ^range.first and d.date <= ^range.last
  end

  @doc "Drops aggregates past retention and visitor hashes older than yesterday."
  def prune(today \\ Date.utc_today()) do
    aggregate_cutoff = Date.add(today, -@retention_days)
    visitor_cutoff = Date.add(today, -1)

    Repo.delete_all(where(from(d in "site_view_days"), [d], d.date < ^aggregate_cutoff))
    Repo.delete_all(where(from(d in "page_view_days"), [d], d.date < ^aggregate_cutoff))
    Repo.delete_all(where(from(v in "view_visitors"), [v], v.date < ^visitor_cutoff))
    :ok
  end
end
