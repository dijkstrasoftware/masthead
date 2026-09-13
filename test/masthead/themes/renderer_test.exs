defmodule Masthead.Themes.RendererTest do
  @moduledoc """
  End-to-end smoke tests for the renderer against the seeded built-in
  themes. We don't assert exact byte-for-byte equality (whitespace differs
  between Liquid and the old HEEx versions) — we check key structural
  elements survive the rewrite.
  """
  use Masthead.DataCase

  alias Masthead.{Accounts, Sites, Content, Themes, Uploads}
  alias Masthead.Themes.Renderer

  setup do
    # Built-in themes are seeded at application boot; if a test re-runs in
    # a fresh sandbox we need to make sure the rows exist within the
    # sandbox connection.
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "renderer-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "rtest#{System.unique_integer([:positive])}",
        "name" => "Renderer Test",
        "title" => "Renderer Test Site",
        "description" => "Test description.",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    {:ok, _post} =
      Content.create_post(site.id, %{
        "title" => "Hello",
        "excerpt" => "An excerpt.",
        "body" => "Just the body.",
        "published" => true
      })

    {:ok, _page} =
      Content.create_page(site.id, %{
        "title" => "About",
        "body" => "About body.",
        "published" => true
      })

    %{site: Sites.get_site!(site.id), user: user}
  end

  describe "render_index/1" do
    test "lists posts and includes site title", %{site: site} do
      posts = Content.list_published_posts(site.id)
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: posts, pages: pages})

      assert out =~ "<!DOCTYPE html>"
      assert out =~ site.title
      assert out =~ "Hello"
      assert out =~ "/posts/hello"
    end

    test "renders empty state when no posts", %{site: site} do
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})
      assert out =~ "No posts yet"
    end
  end

  describe "render_post/1" do
    test "includes title and body_html", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)
      pages = Content.list_published_pages(site.id)
      body_html = Content.render_body(post.body, post.format)

      out =
        Renderer.render_post(%{site: site, post: post, body_html: body_html, pages: pages})

      assert out =~ "<title>"
      assert out =~ post.title
      assert out =~ body_html
    end
  end

  describe "render_page/1" do
    test "renders the page body via body_html", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      pages = Content.list_published_pages(site.id)
      body_html = Content.render_body(page.body, page.format)

      out =
        Renderer.render_page(%{site: site, page: page, body_html: body_html, pages: pages})

      assert out =~ "About body."
    end
  end

  describe "posts_by_tag (DB-backed tag query in templates)" do
    setup %{site: site} do
      {:ok, emacs} = Content.create_tag(site.id, %{"name" => "Emacs"})

      {:ok, _} =
        Content.create_post(site.id, %{
          "title" => "Doom config",
          "body" => "x",
          "published" => true,
          "tag_ids" => [emacs.id]
        })

      {:ok, _} =
        Content.create_post(site.id, %{"title" => "Off topic", "body" => "y", "published" => true})

      :ok
    end

    test "posts_by_tag[slug] returns only posts carrying that tag", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)

      body =
        ~s({% assign e = posts_by_tag["emacs"] %}COUNT={{ e | size }};{% for p in e %}T={{ p.title }};{% endfor %})

      out = Renderer.render_page(%{site: site, page: page, liquid_body: body, pages: [page]})

      assert out =~ "COUNT=1;"
      assert out =~ "T=Doom config;"
      refute out =~ "T=Off topic;"
    end

    test "an unknown tag slug yields an empty collection", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      body = ~s({% assign e = posts_by_tag["nope"] %}COUNT={{ e | size }})
      out = Renderer.render_page(%{site: site, page: page, liquid_body: body, pages: [page]})
      assert out =~ "COUNT=0"
    end
  end

  describe "render_page/1 with an html (Liquid) body" do
    test "renders Liquid tokens against the page context", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Liquid Page",
          "format" => "html",
          "body" => "<h1>{{ site.name }}</h1><p>{{ page.title }}</p>",
          "published" => true
        })

      pages = Content.list_published_pages(site.id)

      out = Renderer.render_page(%{site: site, page: page, liquid_body: page.body, pages: pages})

      assert out =~ "<h1>#{site.name}</h1>"
      assert out =~ "<p>Liquid Page</p>"
    end

    test "passes raw HTML and <script> through unsanitized", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Scripted",
          "format" => "html",
          "body" => ~s|<script>alert("hi")</script><div class="x">raw</div>|,
          "published" => true
        })

      pages = Content.list_published_pages(site.id)

      out = Renderer.render_page(%{site: site, page: page, liquid_body: page.body, pages: pages})

      assert out =~ ~s|<script>alert("hi")</script>|
      assert out =~ ~s|<div class="x">raw</div>|
    end

    test "falls back to the raw body if the Liquid fails to render", %{site: site} do
      # A stored page that somehow holds invalid Liquid must not 500 the
      # public page — the renderer emits the raw body instead.
      [page | _] = Content.list_published_pages(site.id)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          liquid_body: "{% bogus %}plain text",
          pages: [page]
        })

      assert out =~ "plain text"
    end
  end

  describe "render_not_found/1" do
    test "produces a 404 body", %{site: site} do
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_not_found(%{site: site, pages: pages})
      assert out =~ "Not found"
    end
  end

  describe "tags and search" do
    setup %{site: site} do
      {:ok, tag} = Content.create_tag(site.id, %{"name" => "Featured"})

      {:ok, _} =
        Content.create_post(site.id, %{
          "title" => "Tagged post",
          "published" => true,
          "tag_ids" => [tag.id]
        })

      %{tag: tag}
    end

    test "search box and tag pills are hidden unless their tokens are enabled", %{site: site} do
      posts = Content.list_published_posts(site.id)
      pages = Content.list_published_pages(site.id)

      off = Renderer.render_index(%{site: site, posts: posts, pages: pages})
      refute off =~ ~s(action="/search")
      refute off =~ ~s(class="tag-pill")

      on = %{site | theme_tokens: %{"show_search" => "true", "show_tags" => "true"}}
      shown = Renderer.render_index(%{site: on, posts: posts, pages: pages})
      assert shown =~ ~s(action="/search")
      assert shown =~ ~s(class="tag-pill")
      assert shown =~ "Featured"
    end

    test "render_search exposes the query and result count", %{site: site} do
      posts = Content.search_posts(site.id, "tagged")
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_search(%{site: site, posts: posts, query: "tagged", pages: pages})

      assert out =~ "1 result"
      assert out =~ "Tagged post"
    end

    test "render_search with no matches shows the empty-search message", %{site: site} do
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_search(%{site: site, posts: [], query: "zzz", pages: pages})

      assert out =~ "0 results"
      assert out =~ "No posts match your search."
    end
  end

  describe "where_tag through the sandbox" do
    setup %{user: user, site: site} do
      slug = "tagtheme#{System.unique_integer([:positive])}"
      zip_path = build_where_tag_theme_zip(slug)
      {:ok, theme} = Masthead.Themes.Package.install(zip_path, user.id)
      File.rm(zip_path)
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

      {:ok, faq} = Content.create_tag(site.id, %{"name" => "FAQ", "slug" => "faq"})

      {:ok, _} =
        Content.create_post(site.id, %{
          "title" => "How do I publish?",
          "published" => true,
          "tag_ids" => [faq.id]
        })

      {:ok, _} = Content.create_post(site.id, %{"title" => "Untagged news", "published" => true})

      %{site: Sites.get_site!(site.id)}
    end

    test "a page template can query posts by tag", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      pages = Content.list_published_pages(site.id)
      posts = Content.list_published_posts(site.id)
      body_html = Content.render_body(page.body, page.format)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: body_html,
          pages: pages,
          posts: posts
        })

      assert out =~ "How do I publish?"
      refute out =~ "Untagged news"
    end
  end

  describe "escaping" do
    test "site name is HTML-escaped in templates", %{user: user} do
      default = Themes.get_built_in_by_slug("default")

      {:ok, evil} =
        Sites.create_site(%{
          "slug" => "evil#{System.unique_integer([:positive])}",
          "name" => "<script>alert(1)</script>",
          "owner_id" => user.id,
          "theme_id" => default.id
        })

      out = Renderer.render_index(%{site: evil, posts: [], pages: []})
      refute out =~ "<script>alert(1)</script>"
      assert out =~ "&lt;script&gt;"
    end
  end

  describe "tokens" do
    test "default token values appear in the inlined <style>", %{site: site} do
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})

      # Default theme exposes "accent" with default #0066cc
      assert out =~ "--accent: #0066cc"
    end

    test "per-site token override beats the manifest default", %{site: site} do
      {:ok, site} = Sites.update_settings(site, %{"theme_tokens" => %{"accent" => "#ff0000"}})

      site = Sites.get_site!(site.id)
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})

      assert out =~ "--accent: #ff0000"
    end
  end

  describe "object/list tokens" do
    setup %{user: user, site: site} do
      slug = "conttest#{System.unique_integer([:positive])}"
      zip_path = build_container_token_theme_zip(slug)

      {:ok, theme} = Masthead.Themes.Package.install(zip_path, user.id)
      File.rm(zip_path)
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

      {:ok, site: Sites.get_site!(site.id)}
    end

    test "manifest defaults reach the template as a map and a list", %{site: site} do
      out = Renderer.render_index(%{site: site, posts: [], pages: []})

      assert out =~ ~s(data-hero-title="Default hero")
      # The declared default item, filled out against the nested schema.
      assert out =~ ~s(<li data-url="/" data-icon="">Home</li>)
    end

    test "per-site overrides win, and each list item merges the nested schema", %{site: site} do
      {:ok, site} =
        Sites.update_settings(site, %{
          "theme_tokens" => %{
            "hero" => %{"title" => "Custom hero"},
            "links" => [%{"label" => "Docs", "url" => "/docs"}, %{"label" => "Blog"}]
          }
        })

      out = Renderer.render_index(%{site: Sites.get_site!(site.id), posts: [], pages: []})

      assert out =~ ~s(data-hero-title="Custom hero")
      assert out =~ ~s(<li data-url="/docs" data-icon="">Docs</li>)
      # `url` unset on the second item → the nested default ("/"), not a blank.
      assert out =~ ~s(<li data-url="/" data-icon="">Blog</li>)
    end

    test "a file inside an object or a list item resolves to its upload URL", %{site: site} do
      logo = create_upload(site, "logo.png")
      shot = create_upload(site, "shot.png")

      {:ok, site} =
        Sites.update_settings(site, %{
          "theme_tokens" => %{
            "hero" => %{"title" => "Hi", "image" => to_string(logo.id)},
            "links" => [%{"label" => "Docs", "url" => "/docs", "icon" => to_string(shot.id)}]
          }
        })

      out = Renderer.render_index(%{site: Sites.get_site!(site.id), posts: [], pages: []})

      assert out =~ ~s(data-hero-image="#{Uploads.url(logo)}")
      assert out =~ ~s(data-icon="#{Uploads.url(shot)}")
    end

    test "container tokens never reach the CSS cascade", %{site: site} do
      {:ok, site} =
        Sites.update_settings(site, %{
          "theme_tokens" => %{
            "accent" => "#ff0000",
            "hero" => %{"title" => "Custom hero"},
            "links" => [%{"label" => "Docs", "url" => "/docs"}]
          }
        })

      out = Renderer.render_index(%{site: Sites.get_site!(site.id), posts: [], pages: []})

      # A map/list has no CSS custom-property form: only the scalar is declared.
      assert out =~ "--accent: #ff0000"
      refute out =~ "--hero"
      refute out =~ "--links"
    end
  end

  describe "file tokens" do
    test "a selected favicon resolves to a <link rel=icon> and a url() var", %{site: site} do
      upload = create_upload(site, "fav.png")

      {:ok, site} =
        Sites.update_settings(site, %{"theme_tokens" => %{"favicon" => to_string(upload.id)}})

      site = Sites.get_site!(site.id)
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})

      url = Uploads.url(upload)
      assert out =~ ~s(<link rel="icon" href="#{url}")
      assert out =~ "--favicon: url(#{url});"
    end

    test "no favicon selected emits neither an icon link nor a favicon var", %{site: site} do
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})

      refute out =~ ~s(rel="icon")
      refute out =~ "--favicon"
    end

    test "a dangling id (deleted upload) degrades to no favicon", %{site: site} do
      upload = create_upload(site, "gone.png")

      {:ok, site} =
        Sites.update_settings(site, %{"theme_tokens" => %{"favicon" => to_string(upload.id)}})

      {:ok, _} = Uploads.delete_upload(upload)

      site = Sites.get_site!(site.id)
      pages = Content.list_published_pages(site.id)
      out = Renderer.render_index(%{site: site, posts: [], pages: pages})

      refute out =~ ~s(rel="icon")
      refute out =~ "--favicon"
    end
  end

  describe "page options on a beta theme (no render_version)" do
    setup %{user: user, site: site} do
      # A theme with no render_version declares its page options under the
      # legacy "metadata" key and reads them as page.metadata — it must keep
      # rendering exactly as it did before page_options existed.
      slug = "metatest#{System.unique_integer([:positive])}"
      zip_path = build_metadata_theme_zip(slug)

      {:ok, theme} = Masthead.Themes.Package.install(zip_path, user.id)
      File.rm(zip_path)
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})
      site = Sites.get_site!(site.id)

      {:ok, theme: theme, site: site}
    end

    test "manifest defaults reach the template", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      pages = Content.list_published_pages(site.id)
      body_html = Content.render_body(page.body, page.format)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: body_html,
          pages: pages
        })

      assert out =~ ~s(data-layout="contained")
    end

    test "per-page overrides win over manifest defaults", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      {:ok, page} = Content.update_page(page, %{"page_options" => %{"layout" => "wide"}})

      pages = Content.list_published_pages(site.id)
      body_html = Content.render_body(page.body, page.format)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: body_html,
          pages: pages
        })

      assert out =~ ~s(data-layout="wide")
    end

    test "empty-string override falls back to default", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      # Empty values are stripped by the Page changeset's normalize_options.
      {:ok, page} = Content.update_page(page, %{"page_options" => %{"layout" => ""}})
      assert page.page_options == %{}

      pages = Content.list_published_pages(site.id)
      body_html = Content.render_body(page.body, page.format)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: body_html,
          pages: pages
        })

      assert out =~ ~s(data-layout="contained")
    end

    test "unknown keys (from a previous theme) are preserved on save", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)

      {:ok, page} =
        Content.update_page(page, %{"page_options" => %{"from_old_theme" => "still here"}})

      assert page.page_options["from_old_theme"] == "still here"
    end
  end

  describe "render_theme_page/1" do
    setup %{user: user, site: site} do
      slug = "pagetest#{System.unique_integer([:positive])}"
      zip_path = build_theme_page_zip(slug)

      {:ok, theme} = Masthead.Themes.Package.install(zip_path, user.id)
      File.rm(zip_path)
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})
      {:ok, theme: theme, site: Sites.get_site!(site.id)}
    end

    test "renders the chosen page template with the post list", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Writing",
          "format" => "theme",
          "template" => "blog",
          "published" => true
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: Content.list_published_posts(site.id),
          pages: [],
          tags: [],
          current_tag: nil
        })

      assert out =~ "BLOG PAGE: Writing"
      assert out =~ "Hello"
    end

    test "resolves page_metadata for the template (not the global metadata)", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Writing",
          "format" => "theme",
          "template" => "blog",
          "published" => true,
          "page_options" => %{"layout" => "wide"}
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: [],
          pages: [],
          tags: [],
          current_tag: nil
        })

      assert out =~ ~s(data-layout="wide")
    end

    test "a file-typed page_metadata field resolves the upload id to a URL", %{site: site} do
      upload = create_upload(site, "hero.png")

      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Writing",
          "format" => "theme",
          "template" => "blog",
          "published" => true,
          "page_options" => %{"hero_image" => to_string(upload.id)}
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: [],
          pages: [],
          tags: [],
          current_tag: nil
        })

      assert out =~ ~s(data-hero="#{Uploads.url(upload)}")
      refute out =~ ~s(data-hero="#{upload.id}")
    end

    test "object + list fields render, with file ids resolved at every depth", %{site: site} do
      hero_img = create_upload(site, "hero.png")
      photo = create_upload(site, "ada.png")

      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Showcase",
          "format" => "theme",
          "template" => "showcase",
          "published" => true,
          "page_options" => %{
            "hero" => %{"title" => "Welcome", "image" => to_string(hero_img.id)},
            "crew" => [
              %{"name" => "Ada", "photo" => to_string(photo.id)},
              %{"name" => "Lin"}
            ]
          }
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: [],
          pages: [],
          tags: [],
          current_tag: nil
        })

      # Object: nested file id → URL; nested string passes through.
      assert out =~ ~s(data-hero-img="#{Uploads.url(hero_img)}")
      assert out =~ ~s(data-hero-title="Welcome")
      # List: iterated, with each item's file id → URL.
      assert out =~ ~s(<span data-photo="#{Uploads.url(photo)}">Ada</span>)
      assert out =~ ~s(<span data-photo="">Lin</span>)
    end

    test "falls back to :page when the chosen template is missing", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Gone",
          "format" => "theme",
          "template" => "does-not-exist",
          "published" => true
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: [],
          pages: [],
          tags: [],
          current_tag: nil
        })

      # The generic page template renders rather than crashing.
      assert out =~ "GENERIC PAGE: Gone"
    end
  end

  # A theme whose tokens include an `object` and a `list` (each with a nested
  # `file`), rendered into the index so we can prove containers reach templates
  # and stay out of the CSS.
  defp build_container_token_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Container " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [
            %{"key" => "accent", "label" => "Accent", "type" => "color", "default" => "#0066cc"},
            %{
              "key" => "hero",
              "label" => "Hero",
              "type" => "object",
              "fields" => [
                %{
                  "key" => "title",
                  "label" => "Title",
                  "type" => "string",
                  "default" => "Default hero"
                },
                %{"key" => "image", "label" => "Image", "type" => "file", "default" => ""}
              ]
            },
            %{
              "key" => "links",
              "label" => "Links",
              "type" => "list",
              "item_label" => "Link",
              "default" => [%{"label" => "Home"}],
              "fields" => [
                %{"key" => "label", "label" => "Label", "type" => "string", "default" => ""},
                %{"key" => "url", "label" => "URL", "type" => "url", "default" => "/"},
                %{"key" => "icon", "label" => "Icon", "type" => "file", "default" => ""}
              ]
            }
          ],
          "metadata" => []
        }),
      "templates/layout.liquid" =>
        "<html><head></head><body>{{ theme.css }}{{ content }}</body></html>",
      "templates/index.liquid" =>
        ~s(<section data-hero-title="{{ theme.tokens.hero.title }}" data-hero-image="{{ theme.tokens.hero.image }}">) <>
          ~s(<ul>{% for link in theme.tokens.links %}<li data-url="{{ link.url }}" data-icon="{{ link.icon }}">{{ link.label }}</li>{% endfor %}</ul>) <>
          "</section>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => ":root { --accent: #0066cc; }"
    }

    tmp = Path.join(System.tmp_dir!(), "conttheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  # A theme exposing one page template (blog) with its own page_metadata.
  defp build_theme_page_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Pages " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [],
          "metadata" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>GENERIC PAGE: {{ page.title | escape }}</article>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "templates/pages/blog.liquid" =>
        ~s(<section data-layout="{{ page.metadata.layout }}" data-hero="{{ page.metadata.hero_image }}">) <>
          "BLOG PAGE: {{ page.title | escape }}" <>
          "{% for p in posts %}<li>{{ p.title | escape }}</li>{% endfor %}</section>",
      # The page's settings now live in a sidecar config, not the manifest.
      "templates/pages/blog.json" =>
        Jason.encode!(%{
          "label" => "Blog",
          "metadata" => [
            %{
              "key" => "layout",
              "label" => "Layout",
              "type" => "select",
              "options" => ["contained", "wide"],
              "default" => "contained"
            },
            %{"key" => "hero_image", "label" => "Hero", "type" => "file", "default" => ""}
          ]
        }),
      "templates/pages/showcase.liquid" =>
        ~s(<div data-hero-img="{{ page.metadata.hero.image }}" data-hero-title="{{ page.metadata.hero.title | escape }}">) <>
          "{% for m in page.metadata.crew %}<span data-photo=\"{{ m.photo }}\">{{ m.name | escape }}</span>{% endfor %}</div>",
      "templates/pages/showcase.json" =>
        Jason.encode!(%{
          "label" => "Showcase",
          "metadata" => [
            %{
              "key" => "hero",
              "label" => "Hero",
              "type" => "object",
              "fields" => [
                %{"key" => "title", "label" => "T", "type" => "string", "default" => "Hi"},
                %{"key" => "image", "label" => "I", "type" => "file", "default" => ""}
              ]
            },
            %{
              "key" => "crew",
              "label" => "Crew",
              "type" => "list",
              "default" => [],
              "fields" => [
                %{"key" => "name", "label" => "N", "type" => "string", "default" => ""},
                %{"key" => "photo", "label" => "P", "type" => "file", "default" => ""}
              ]
            }
          ]
        }),
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "pagetheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  # Helper: store an upload for the site via the real Uploads pipeline so
  # the resolved URL matches what the renderer produces in this env.
  defp create_upload(site, filename) do
    tmp = Path.join(System.tmp_dir!(), "up-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "not-a-real-png-but-bytes")

    {:ok, upload} =
      Uploads.store_image(site, %{
        filename: filename,
        content_type: "image/png",
        path: tmp
      })

    File.rm(tmp)
    upload
  end

  # Helper: write a minimal zipped theme whose page template queries posts by
  # tag via the `where_tag` filter, so we can prove the filter is wired into
  # the sandbox end-to-end.
  defp build_where_tag_theme_zip(slug) do
    page_template = """
    {% assign faqs = posts | where_tag: "faq" %}
    <ul>{% for p in faqs %}<li>{{ p.title | escape }}</li>{% endfor %}</ul>
    """

    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Tag " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [],
          "metadata" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => page_template,
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "tagtheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  describe "render version v1" do
    setup %{user: user, site: site} do
      slug = "v1test#{System.unique_integer([:positive])}"
      zip_path = build_v1_theme_zip(slug)

      {:ok, theme} = Masthead.Themes.Package.install(zip_path, user.id)
      File.rm(zip_path)
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

      {:ok, theme: theme, site: Sites.get_site!(site.id)}
    end

    test "page options reach the template under page.page_options", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      {:ok, page} = Content.update_page(page, %{"page_options" => %{"layout" => "wide"}})
      pages = Content.list_published_pages(site.id)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: Content.render_body(page.body, page.format),
          pages: pages
        })

      assert out =~ ~s(data-layout="wide")
    end

    test "page options fall back to the manifest default", %{site: site} do
      [page | _] = Content.list_published_pages(site.id)
      pages = Content.list_published_pages(site.id)

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          body_html: Content.render_body(page.body, page.format),
          pages: pages
        })

      assert out =~ ~s(data-layout="contained")
    end

    test "a theme page reads its sidecar config's page options", %{site: site} do
      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Journal",
          "format" => "theme",
          "template" => "blog",
          "published" => true,
          "page_options" => %{"heading" => "Latest"}
        })

      out =
        Renderer.render_theme_page(%{
          site: site,
          page: page,
          posts: Content.list_published_posts(site.id),
          pages: Content.list_published_pages(site.id)
        })

      assert out =~ ~s(data-heading="Latest")
    end

    test "post options reach the post template", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)

      {:ok, post} =
        Content.update_post(post, %{"post_options" => %{"subtitle" => "A subtitle"}})

      out =
        Renderer.render_post(%{
          site: site,
          post: post,
          pages: Content.list_published_pages(site.id),
          body_html: "<p>Body.</p>"
        })

      assert out =~ ~s(data-subtitle="A subtitle")
    end

    test "post options fall back to the manifest default", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)

      out =
        Renderer.render_post(%{
          site: site,
          post: post,
          pages: Content.list_published_pages(site.id),
          body_html: "<p>Body.</p>"
        })

      assert out =~ ~s(data-subtitle="")
    end

    test "posts in a list carry their own options", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)
      {:ok, _} = Content.update_post(post, %{"post_options" => %{"subtitle" => "In the list"}})

      out =
        Renderer.render_index(%{
          site: site,
          posts: Content.list_published_posts(site.id),
          pages: Content.list_published_pages(site.id)
        })

      assert out =~ ~s(data-subtitle="In the list")
    end

    test "a file post option resolves to the upload's URL", %{site: site} do
      upload = create_upload(site, "cover.png")
      [post | _] = Content.list_published_posts(site.id)

      {:ok, post} =
        Content.update_post(post, %{"post_options" => %{"cover" => to_string(upload.id)}})

      out =
        Renderer.render_post(%{
          site: site,
          post: post,
          pages: Content.list_published_pages(site.id),
          body_html: "<p>Body.</p>"
        })

      assert out =~ ~s(data-cover="#{Uploads.url(upload)}")
    end

    test "posts reached through posts_by_tag carry their options too", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)
      {:ok, tag} = Content.create_tag(site.id, %{"name" => "Featured"})

      {:ok, post} =
        Content.update_post(post, %{
          "tag_ids" => [to_string(tag.id)],
          "post_options" => %{"subtitle" => "Via the tag query"}
        })

      {:ok, page} =
        Content.create_page(site.id, %{
          "title" => "Tagged",
          "format" => "html",
          "published" => true,
          "body" =>
            ~s({% for p in posts_by_tag["featured"] %}S={{ p.post_options.subtitle }};{% endfor %})
        })

      out =
        Renderer.render_page(%{
          site: site,
          page: page,
          liquid_body: page.body,
          pages: Content.list_published_pages(site.id)
        })

      assert out =~ "S=Via the tag query;"
      assert post.post_options["subtitle"] == "Via the tag query"
    end

    test "unknown post option keys survive a theme switch", %{site: site} do
      [post | _] = Content.list_published_posts(site.id)

      {:ok, post} =
        Content.update_post(post, %{"post_options" => %{"from_old_theme" => "still here"}})

      assert post.post_options["from_old_theme"] == "still here"
    end
  end

  # A beta theme (no render_version): page options declared as "metadata",
  # read in the template as page.metadata.
  defp build_metadata_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Meta " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [],
          "metadata" => [
            %{
              "key" => "layout",
              "label" => "Layout",
              "type" => "select",
              "options" => ["contained", "wide"],
              "default" => "contained"
            }
          ]
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" =>
        "<article data-layout=\"{{ page.metadata.layout }}\">{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "metatest-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  # A v1 theme: page_options + post_options, read under their own names.
  defp build_v1_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "V1 " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "render_version" => "v1",
          "tokens" => [],
          "page_options" => [
            %{
              "key" => "layout",
              "label" => "Layout",
              "type" => "select",
              "options" => ["contained", "wide"],
              "default" => "contained"
            }
          ],
          "post_options" => [
            %{"key" => "subtitle", "label" => "Subtitle", "type" => "string", "default" => ""},
            %{"key" => "cover", "label" => "Cover", "type" => "file", "default" => ""}
          ]
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" =>
        "{% for p in posts %}" <>
          ~s(<li data-subtitle="{{ p.post_options.subtitle }}">{{ p.title | escape }}</li>) <>
          "{% endfor %}",
      "templates/post.liquid" =>
        ~s(<article data-subtitle="{{ post.post_options.subtitle }}" data-cover="{{ post.post_options.cover }}">) <>
          "{{ body_html }}</article>",
      "templates/page.liquid" =>
        ~s(<article data-layout="{{ page.page_options.layout }}">{{ body_html }}</article>),
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "templates/pages/blog.liquid" =>
        ~s(<section data-heading="{{ page.page_options.heading }}">) <>
          "{% for p in posts %}<li>{{ p.title | escape }}</li>{% endfor %}</section>",
      "templates/pages/blog.json" =>
        Jason.encode!(%{
          "label" => "Blog",
          "page_options" => [
            %{"key" => "heading", "label" => "Heading", "type" => "string", "default" => "Posts"}
          ]
        }),
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "v1test-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end
end
