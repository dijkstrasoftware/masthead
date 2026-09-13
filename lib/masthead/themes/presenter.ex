defmodule Masthead.Themes.Presenter do
  @moduledoc """
  Project Ecto schemas into plain maps for use inside Liquid templates.

  This module is the **only** code path through which schema data reaches
  themes. If a field isn't projected here, it isn't reachable from a
  template — that's the trust boundary. Don't widen the projections
  in-place inside the renderer; extend the presenter.

  Keys are strings (Liquid is string-keyed) and the projected shapes are
  deliberately narrow — IDs, foreign keys, internal timestamps, and raw
  unsanitized bodies are not exposed.
  """

  alias Masthead.Sites.Site
  alias Masthead.Content.{Post, Page, Tag}
  alias Masthead.Themes.CssSanitizer

  @doc "Project a Site, including the per-site CSS overrides string."
  def site(%Site{} = s) do
    %{
      "name" => s.name,
      "title" => s.title,
      "description" => s.description,
      "slug" => s.slug,
      "css_overrides" => CssSanitizer.sanitize_overrides(s.theme_css_overrides),
      "homepage_slug" => homepage_slug(s)
    }
  end

  # Returns the slug of the page that's currently set as the site's
  # homepage, or `nil` if none is set. Themes use this to know whether
  # the page being rendered is the site's home — useful for applying a
  # special layout or layout class only there.
  defp homepage_slug(%Site{homepage_page_id: nil}), do: nil

  defp homepage_slug(%Site{homepage_page: %Masthead.Content.Page{slug: slug}}), do: slug

  defp homepage_slug(%Site{homepage_page_id: id}) when is_integer(id) do
    # belongs_to wasn't preloaded — one cheap query (id PK lookup).
    case Masthead.Repo.get(Masthead.Content.Page, id) do
      %Masthead.Content.Page{slug: slug} -> slug
      _ -> nil
    end
  end

  defp homepage_slug(_), do: nil

  def post(%Post{} = p) do
    %{
      "title" => p.title,
      "slug" => p.slug,
      "excerpt" => p.excerpt,
      "published_at" => p.published_at,
      "url" => "/posts/" <> p.slug,
      "tags" => tags_of(p),
      "post_options" => p.post_options || %{}
    }
  end

  # Project a post's tags as plain maps. Defensive against an unloaded
  # association so a caller that forgets to preload gets `[]` rather than a
  # crash on `%Ecto.Association.NotLoaded{}`.
  defp tags_of(%Post{tags: tags}) when is_list(tags) do
    Enum.map(tags, fn t -> %{"name" => t.name, "slug" => t.slug} end)
  end

  defp tags_of(_), do: []

  def page(%Page{} = pg) do
    %{
      "title" => pg.title,
      "slug" => pg.slug,
      "format" => pg.format,
      # For theme pages: the chosen templates/pages/<template>.liquid name.
      "template" => pg.template,
      "url" => "/" <> pg.slug,
      "page_options" => pg.page_options || %{}
    }
  end

  @doc """
  Project the set of tags a blog page can be filtered by. `current_slug`
  (or `nil`) marks the active tag with `"active" => true`, so a theme can
  highlight the selected filter chip. Each tag is a `name`/`slug`/`active`
  map; the theme builds its own filter links (e.g. `?tag={{ tag.slug }}`),
  and because every rendered slug comes from this list, the resulting query
  is guaranteed to reference a tag that exists on the site.
  """
  def tags(list, current_slug \\ nil) when is_list(list) do
    Enum.map(list, fn %Tag{} = t ->
      %{"name" => t.name, "slug" => t.slug, "active" => t.slug == current_slug}
    end)
  end

  @doc """
  Project the single tag a blog page is currently filtered by, or `nil` when
  the page is showing its full list. Lets a theme render a heading or a
  clear-filter link.
  """
  def tag(%Tag{} = t), do: %{"name" => t.name, "slug" => t.slug}
  def tag(nil), do: nil

  @doc "Convenience: project a list of posts."
  def posts(list) when is_list(list), do: Enum.map(list, &post/1)

  @doc "Convenience: project a list of pages."
  def pages(list) when is_list(list), do: Enum.map(list, &page/1)
end
