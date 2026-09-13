defmodule Masthead.Themes.Renderer do
  @moduledoc """
  Top-level theme render API.

  The public controller calls one of `render_index/1`, `render_post/1`,
  `render_page/1`, `render_theme_page/1`, `render_not_found/1`,
  `render_search/1` with a plain map of assigns, and gets back a rendered body
  ready to send.

  This module resolves the site's theme, loads it through
  `Masthead.Themes.Loader`, and hands the work to the renderer the theme's
  manifest pins itself to via `render_version`:

    * no `render_version` (or `"beta"`) — `Masthead.Themes.Renderer.Beta`
    * `"v1"` — `Masthead.Themes.Renderer.V1`

  Those modules are **frozen**. A change to how themes render means copying the
  newest one to the next version and teaching `Masthead.Themes.Manifest` the
  new name — never editing a version that has shipped, so a site keeps
  rendering the way it did the day it was built.

  All rendering is sandboxed via `Masthead.Themes.Sandbox` — templates can't
  reach Elixir, the file system, or the database.
  """

  alias Masthead.Themes
  alias Masthead.Themes.Loader
  alias Masthead.Themes.Renderer.{Beta, V1}

  @doc """
  Render the site homepage (post list).

  Like `render_theme_page/1`, `tags`/`current_tag` are exposed (optional) so a
  theme can render a tag-filter bar on the index. A theme gates the bar on its
  own `show_tags` token; the data is always supplied.
  """
  def render_index(assigns), do: dispatch(:render_index, assigns)

  @doc """
  Render a single blog post. The full published-posts list is exposed as
  `posts` too, so a post template can pull related/tagged posts.
  """
  def render_post(assigns), do: dispatch(:render_post, assigns)

  @doc """
  Render a standalone page (markdown or html). The full published-posts list
  is exposed as `posts` so any page can query posts by tag and render them as
  generic content blocks.
  """
  def render_page(assigns), do: dispatch(:render_page, assigns)

  @doc """
  Render a theme page: a page whose layout is a Liquid template from the
  theme's `templates/pages/` folder (chosen via `page.template`). Theme pages
  have no editable body; they always receive the full (tag-filtered) post list,
  plus `tags`/`current_tag` so a template can render its own filter UI.
  """
  def render_theme_page(assigns), do: dispatch(:render_theme_page, assigns)

  @doc "Render the site-scoped 404."
  def render_not_found(assigns), do: dispatch(:render_not_found, assigns)

  @doc """
  Render public search results. Reuses the theme's `index` template (so no
  new required template is introduced) and exposes `search_query` and
  `search_count` so a theme can branch on `{% if search_query %}` to show a
  results heading. `posts` is the already-filtered result set.
  """
  def render_search(assigns), do: dispatch(:render_search, assigns)

  defp dispatch(fun, %{site: site} = assigns) do
    entry = site |> resolve_theme() |> Loader.fetch!()

    apply(module_for(entry.manifest.render_version), fun, [assigns, entry])
  end

  defp module_for("v1"), do: V1
  defp module_for(_render_version), do: Beta

  defp resolve_theme(%Masthead.Sites.Site{theme_id: id}) when is_integer(id) do
    Themes.get_theme!(id)
  end

  defp resolve_theme(_) do
    Themes.get_built_in_by_slug("default") ||
      raise "no default theme seeded — run Masthead.Themes.Seed.run/0"
  end
end
