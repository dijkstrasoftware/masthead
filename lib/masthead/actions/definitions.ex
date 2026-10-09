defmodule Masthead.Actions.Definitions do
  @moduledoc """
  Registry of known action types, keyed by `key`.

  Each definition supplies the values used to *create* an action row
  (`message`, `priority`, `path`) plus the render-time presentation that is
  intentionally NOT persisted (`title`, `cta`). To add a new action type,
  add an entry here and call `Masthead.Actions.create_action(site, key)`.

  `path` is a function of the site so it can embed the site slug; it returns
  a plain admin path string (this module stays free of web route helpers).
  """

  alias Masthead.Sites.Site

  @definitions %{
    "customize_theme" => %{
      title: "Make it yours",
      message: &__MODULE__.customize_theme_message/1,
      priority: 120,
      cta: "Open theme settings",
      path: &__MODULE__.theme_path/1
    },
    "create_first_post" => %{
      title: "Create your first post",
      message: "Publish your first post to start sharing updates with your readers.",
      priority: 100,
      cta: "Create post",
      remindable: true,
      path: &__MODULE__.new_post_path/1
    },
    "create_first_page" => %{
      title: "Create your first page",
      message: "Add a page like About or Contact to give your site some structure.",
      priority: 100,
      cta: "Create page",
      remindable: true,
      path: &__MODULE__.new_page_path/1
    },
    "import_site" => %{
      title: "Import your old site",
      message: "Coming from another platform? Import your posts, pages, and images.",
      priority: 10,
      cta: "Import a site",
      path: &__MODULE__.import_path/1
    },
    "set_description" => %{
      title: "Set the description",
      message: "Add a description so visitors and search engines know what your site is about.",
      priority: 100,
      cta: "Set description",
      path: &__MODULE__.settings_path/1
    }
  }

  @doc "Returns the definition map for `key`, or `nil` if unknown."
  def get(key), do: Map.get(@definitions, key)

  @doc "All defined action keys."
  def keys, do: Map.keys(@definitions)

  @doc "Keys of action types that may trigger a one-off reminder email."
  def remindable_keys do
    for {key, %{remindable: true}} <- @definitions, do: key
  end

  @doc "Human-readable title for an action `key`, falling back to a humanized key."
  def title(key) do
    case get(key) do
      %{title: title} -> title
      _ -> humanize(key)
    end
  end

  @doc "Button label for an action `key`, or `nil` when the type defines none."
  def cta(key) do
    case get(key) do
      %{cta: cta} -> cta
      _ -> nil
    end
  end

  @doc """
  Builds the attrs for inserting an action of type `key` for `site`, drawing
  defaults from the registry. Returns `nil` for unknown keys.
  """
  def build_attrs(key, %Site{} = site) do
    case get(key) do
      nil ->
        nil

      %{message: message, priority: priority, path: path_fun} ->
        %{
          "key" => key,
          "site_id" => site.id,
          "status" => "pending",
          "message" => if(is_function(message, 1), do: message.(site), else: message),
          "priority" => priority,
          "path" => path_fun.(site)
        }
    end
  end

  @doc false
  def customize_theme_message(%Site{} = site) do
    manifest = Masthead.Themes.manifest_for_site(site) || %{}
    tokens = Map.get(manifest, "tokens", Map.get(manifest, :tokens))

    labels =
      if is_list(tokens),
        do: Enum.map(tokens, &(&1["label"] || &1[:label] || &1["key"] || &1[:key])),
        else: []

    name = Map.get(manifest, "name", Map.get(manifest, :name)) || "Your theme"

    case labels do
      [] ->
        "Tune your theme's look so the site feels like yours."

      _ ->
        examples =
          labels
          |> Enum.reject(&is_nil/1)
          |> Enum.take(3)
          |> Enum.map_join(", ", &String.downcase/1)

        "#{name} has #{length(labels)} settings — #{examples} and more."
    end
  end

  @doc false
  def theme_path(%Site{slug: slug}), do: "/#{slug}/theme"
  @doc false
  def settings_path(%Site{slug: slug}), do: "/#{slug}/settings"
  @doc false
  def new_post_path(%Site{slug: slug}), do: "/#{slug}/posts/new"
  @doc false
  def new_page_path(%Site{slug: slug}), do: "/#{slug}/pages/new"
  @doc false
  def import_path(%Site{slug: slug}), do: "/#{slug}/import"

  defp humanize(key) do
    key
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
