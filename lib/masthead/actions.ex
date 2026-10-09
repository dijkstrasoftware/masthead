defmodule Masthead.Actions do
  @moduledoc """
  One-off, site-scoped tasks ("actions") surfaced in the admin checklist.

  Actions are created from a registry of known types
  (`Masthead.Actions.Definitions`) and are idempotent on both ends:

    * `create_action/2` is a no-op if the `(site, key)` action already
      exists (the action is a "one-off").
    * `complete_action/2` is a no-op if the action is missing or already
      completed.
  """
  import Ecto.Query

  alias Masthead.Realtime
  alias Masthead.Repo
  alias Masthead.Sites.Site
  alias Masthead.Actions.{Action, Definitions}

  @doc """
  Creates the action of type `key` for `site`, drawing its message/priority/
  path from the registry. Idempotent: a duplicate `(site, key)` is ignored,
  so it is safe to call on every site creation. Returns `{:ok, action}`,
  `{:ok, :exists}` when it already existed, or `{:error, :unknown_key}`.
  """
  def create_action(%Site{} = site, key) when is_binary(key) do
    case Definitions.build_attrs(key, site) do
      nil ->
        {:error, :unknown_key}

      attrs ->
        %Action{}
        |> Action.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:site_id, :key])
        |> case do
          {:ok, %Action{id: nil}} ->
            {:ok, :exists}

          {:ok, action} ->
            Realtime.actions_changed(site.id)
            {:ok, action}

          other ->
            other
        end
    end
  end

  @doc """
  Creates a custom, user-authored action on `site` from free-text
  `title` + `message` and an optional `path` link. A relative path
  (`/settings`) is scoped to the site's admin (`/<slug>/settings`). Gets a
  unique generated key so it never collides with the predefined types.
  Returns `{:ok, action}` or `{:error, changeset}`.
  """
  def create_custom_action(%Site{} = site, %{} = attrs) do
    %Action{}
    |> Action.changeset(%{
      "key" => "custom_#{System.unique_integer([:positive])}",
      "site_id" => site.id,
      "status" => "pending",
      "title" => attrs["title"],
      "message" => attrs["message"],
      "path" => site_path(site, attrs["path"]),
      "priority" => 100
    })
    |> Ecto.Changeset.validate_required([:title])
    |> Ecto.Changeset.validate_length(:title, max: 80)
    |> Ecto.Changeset.validate_length(:message, max: 200)
    |> Repo.insert()
    |> case do
      {:ok, action} ->
        Realtime.actions_changed(site.id)
        {:ok, action}

      other ->
        other
    end
  end

  @doc """
  Onboarding milestone — called once a site gains its first post or page.
  Staggers in the "set description" nudge (unless a description is already
  set) so a brand-new, empty site isn't overwhelmed with it up front.
  Idempotent. Accepts a `%Site{}` or a bare site id.
  """
  def reached_first_content(%Site{} = site) do
    if blank?(site.description), do: create_action(site, "set_description")
    :ok
  end

  def reached_first_content(site_id) when is_integer(site_id) do
    site_id |> Masthead.Sites.get_site!() |> reached_first_content()
  end

  @doc """
  Marks the `(site, key)` action completed. Accepts a `%Site{}` or a bare
  site id. Idempotent: returns `:ok` whether the action was pending, already
  completed, or absent.
  """
  def complete_action(%Site{id: site_id}, key), do: complete_action(site_id, key)

  def complete_action(site_id, key) when is_integer(site_id) and is_binary(key) do
    {count, _} =
      from(a in Action,
        where: a.site_id == ^site_id and a.key == ^key and a.status != "completed"
      )
      |> Repo.update_all(set: [status: "completed", updated_at: now()])

    if count > 0, do: Realtime.actions_changed(site_id)
    :ok
  end

  @doc """
  Dismisses the `(site, key)` action — the owner has chosen to skip it.
  Accepts a `%Site{}` or a bare site id. Only affects a `pending` action
  (a completed one stays completed). Idempotent: returns `:ok` regardless.
  """
  def dismiss_action(%Site{id: site_id}, key), do: dismiss_action(site_id, key)

  def dismiss_action(site_id, key) when is_integer(site_id) and is_binary(key) do
    {count, _} =
      from(a in Action,
        where: a.site_id == ^site_id and a.key == ^key and a.status == "pending"
      )
      |> Repo.update_all(set: [status: "dismissed", updated_at: now()])

    if count > 0, do: Realtime.actions_changed(site_id)
    # Skipping "Make it yours" still unlocks the theme-page todos.
    if count > 0 and key == "customize_theme",
      do: site_id |> Masthead.Sites.get_site!() |> sync_theme_page_actions()

    :ok
  end

  @doc """
  Keeps one `theme_page:<name>` todo per page template of the site's current
  theme: creates missing ones and dismisses pending ones whose template the
  theme no longer ships (completed ones stay). A no-op while
  `customize_theme` is still pending, so page todos only appear after it.
  """
  def sync_theme_page_actions(%Site{id: site_id} = site) do
    if Repo.exists?(
         from a in Action,
           where: a.site_id == ^site_id and a.key == "customize_theme" and a.status == "pending"
       ) do
      :ok
    else
      manifest = Masthead.Themes.manifest_for_site(site) || %{}
      # ponytail: capped at 3 theme-page todos; lift if themes ship many pages
      names = manifest |> Masthead.Themes.Loader.manifest_page_template_names() |> Enum.take(3)
      keys = Enum.map(names, &("theme_page:" <> &1))

      {dismissed, _} =
        from(a in Action,
          where:
            a.site_id == ^site_id and a.status == "pending" and
              like(a.key, "theme_page:%") and a.key not in ^keys
        )
        |> Repo.update_all(set: [status: "dismissed", updated_at: now()])

      created =
        Enum.count(names, fn name ->
          match?(
            {:ok, %Action{id: id}} when not is_nil(id),
            insert_theme_page(site, manifest, name)
          )
        end)

      if dismissed + created > 0, do: Realtime.actions_changed(site_id)
      :ok
    end
  end

  defp insert_theme_page(site, manifest, name) do
    config =
      case Map.get(manifest, "page_configs", Map.get(manifest, :page_configs)) do
        %{} = configs -> configs[name] || %{}
        _ -> %{}
      end

    label =
      config["label"] || config[:label] ||
        name |> String.replace(["-", "_"], " ") |> String.capitalize()

    theme = Map.get(manifest, "name", Map.get(manifest, :name)) || "your theme"

    %Action{}
    |> Action.changeset(%{
      "key" => "theme_page:" <> name,
      "site_id" => site.id,
      "status" => "pending",
      "title" => "Your theme can build a #{label} page",
      "message" =>
        config["description"] || config[:description] || "A dedicated page laid out by #{theme}.",
      "path" => "/#{site.slug}/pages/new?template=#{URI.encode_www_form(name)}",
      "priority" => 90
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:site_id, :key])
  end

  @doc "Pending actions for `site`, highest priority first."
  def list_pending(%Site{id: site_id}), do: Repo.all(pending_query(site_id))

  @doc "Count of pending actions for `site` (used for the checklist badge)."
  def count_pending(%Site{id: site_id}) do
    Repo.aggregate(
      from(a in Action, where: a.site_id == ^site_id and a.status == "pending"),
      :count
    )
  end

  @doc "The single highest-priority pending action for `site`, or `nil`."
  def top_action(%Site{id: site_id}) do
    site_id |> pending_query() |> limit(1) |> Repo.one()
  end

  @doc """
  Reminder-eligible actions: still pending, of a remindable type, created more
  than `older_than_days` ago, never reminded, on an active site. Returns
  actions with `:site` and the site's `:members` preloaded — the worker picks
  the eligible members (confirmed, active, opted-in) to email.
  """
  def due_reminders(older_than_days \\ 7) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-older_than_days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    keys = Definitions.remindable_keys()

    Repo.all(
      from a in Action,
        join: s in assoc(a, :site),
        where:
          a.status == "pending" and a.key in ^keys and
            a.inserted_at < ^cutoff and is_nil(a.reminded_at) and
            is_nil(s.disabled_at) and is_nil(s.deleted_at),
        preload: [site: {s, [:members]}]
    )
  end

  @doc "Records that a reminder email was sent for `action` (so it never repeats)."
  def mark_reminded(%Action{id: id}) do
    from(a in Action, where: a.id == ^id)
    |> Repo.update_all(set: [reminded_at: now(), updated_at: now()])

    :ok
  end

  @doc "Render-time title for an action."
  def title(%Action{title: title}) when is_binary(title) and title != "", do: title
  def title(%Action{key: key}), do: Definitions.title(key)

  @doc "Render-time button label for an action, or `nil`."
  def cta(%Action{key: "theme_page:" <> _}), do: "Create page"
  def cta(%Action{key: key}), do: Definitions.cta(key)

  defp pending_query(site_id) do
    from a in Action,
      where: a.site_id == ^site_id and a.status == "pending",
      # `id` is the final tiebreak so equal-priority actions created in the
      # same second still have a stable, creation-order ranking.
      order_by: [desc: a.priority, asc: a.inserted_at, asc: a.id]
  end

  defp site_path(%Site{slug: slug}, "/" <> rest = path) do
    if rest == slug or String.starts_with?(rest, slug <> "/"),
      do: path,
      else: "/#{slug}/#{rest}"
  end

  defp site_path(_site, path), do: path

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
end
