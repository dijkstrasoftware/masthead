defmodule Masthead.Content.PreviewImportTest do
  use Masthead.DataCase, async: true

  alias Masthead.{Accounts, Content, Repo, Sites, Themes, Uploads}
  alias Masthead.Content.SiteArchive

  setup do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "preview-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "preview#{System.unique_integer([:positive])}",
        "name" => "Preview Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    %{site: site, user: user, theme: default}
  end

  defp build_zip(files) do
    base = Path.join(System.tmp_dir!(), "preview-src-#{System.unique_integer([:positive])}")

    for {rel, content} <- files do
      abs = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end

    zip = Path.join(System.tmp_dir!(), "preview-#{System.unique_integer([:positive])}.zip")
    rels = files |> Map.keys() |> Enum.map(&String.to_charlist/1)
    {:ok, _} = :zip.create(String.to_charlist(zip), rels, cwd: String.to_charlist(base))

    on_exit(fn ->
      File.rm_rf(base)
      File.rm(zip)
    end)

    zip
  end

  @home_page """
  ---
  { "title": "Home", "format": "theme", "template": "home",
    "page_options": { "hero": { "heading": "Hello" }, "layout": "wide" } }
  ---
  """

  @about_page """
  ---
  { "show_in_nav": false }
  ---
  ## About us

  ![Cover](/assets/cover.png)
  """

  defp preview_files(theme) do
    %{
      "preview.json" =>
        Jason.encode!(%{
          "site" => %{
            "name" => "Ignored",
            "title" => "Acme — we make things",
            "description" => "A demo site.",
            "css_overrides" => ".intro { color: red; }",
            "homepage" => "home"
          },
          "tokens" => %{"accent" => "#d9480f", "max_width" => "1120px"},
          "posts" => [
            %{
              "title" => "Hello",
              "slug" => "hello",
              "published_at" => "2026-01-15",
              "tags" => ["Writing", %{"name" => "Launch"}],
              "post_options" => %{"featured_image" => "/assets/cover.png"},
              "body" => "A post body."
            }
          ]
        }),
      "preview.local.json" =>
        Jason.encode!(%{
          "tokens" => %{"accent" => "#000000", "logo" => "/assets/cover.png"},
          "pages" => %{"home" => %{"page_options" => %{"layout" => "narrow"}}}
        }),
      "preview/pages/home.md" => @home_page,
      "preview/pages/about.md" => @about_page,
      "assets/cover.png" => "fake-png-bytes",
      "assets/fonts/body.woff2" => "fake-font",
      "manifest.json" => Jason.encode!(%{"slug" => theme.slug, "version" => theme.version}),
      "templates/layout.liquid" => "{{ content }}"
    }
  end

  test "imports pages, posts, options, assets and site settings", %{
    site: site,
    user: user,
    theme: theme
  } do
    {:ok, summary} = SiteArchive.import(site, build_zip(preview_files(theme)), user.id)

    assert length(summary.pages) == 2
    assert length(summary.posts) == 1
    assert summary.uploads == 1
    assert summary.skipped_assets == 1
    assert summary.skipped_content == []

    [upload] = Uploads.list_uploads(site.id)
    upload_id = to_string(upload.id)

    pages = Map.new(Content.list_pages(site.id), &{&1.slug, &1})
    home = pages["home"]
    assert home.published
    assert home.format == "theme"
    assert home.template == "home"
    assert home.page_options == %{"hero" => %{"heading" => "Hello"}, "layout" => "narrow"}

    about = pages["about"]
    assert about.title == "About"
    refute about.show_in_nav
    assert about.body =~ Uploads.url(upload)
    refute about.body =~ "/assets/cover.png"

    [post] = site.id |> Content.list_posts() |> Repo.preload(:tags)
    assert post.published
    assert post.published_at == ~U[2026-01-15 00:00:00Z]
    assert post.post_options == %{"featured_image" => upload_id}
    assert post.tags |> Enum.map(& &1.slug) |> Enum.sort() == ["launch", "writing"]

    site = Sites.get_site!(site.id)
    assert site.name == "Preview Test"
    assert site.title == "Acme — we make things"
    assert site.description == "A demo site."
    assert site.theme_css_overrides == ".intro { color: red; }"
    assert site.homepage_page_id == home.id

    assert site.theme_tokens == %{
             "accent" => "#000000",
             "max_width" => "1120px",
             "logo" => upload_id
           }
  end

  test "the sidebar's content list wins over preview files", %{site: site, theme: theme} do
    files =
      Map.put(
        preview_files(theme),
        "preview.local.json",
        Jason.encode!(%{"content" => %{"pages" => [%{"title" => "Only", "slug" => "only"}]}})
      )

    {:ok, summary} = SiteArchive.import(site, build_zip(files))

    assert Enum.map(summary.pages, & &1.slug) == ["only"]
  end

  test "detects a preview zipped inside its theme folder", %{site: site, theme: theme} do
    files = Map.new(preview_files(theme), fn {rel, content} -> {"my-theme/" <> rel, content} end)

    {:ok, summary} = SiteArchive.import(site, build_zip(files))

    assert length(summary.pages) == 2
  end

  test "reports content that can't be created", %{site: site, theme: theme} do
    {:ok, _} = Content.create_page(site.id, %{"title" => "About", "slug" => "about"})

    {:ok, summary} = SiteArchive.import(site, build_zip(preview_files(theme)))

    assert [{"preview/pages/about.md", {:invalid, _}}] = summary.skipped_content
  end

  test "errors when the preview is for another theme or version", %{site: site, theme: theme} do
    other =
      Map.put(preview_files(theme), "manifest.json", ~s({"slug": "studio", "version": "2.0.0"}))

    installed = "#{theme.slug} #{theme.version}"

    assert {:error, {:theme_mismatch, ^installed, "studio 2.0.0"}} =
             SiteArchive.import(site, build_zip(other))

    older =
      Map.put(
        preview_files(theme),
        "manifest.json",
        ~s({"slug": "#{theme.slug}", "version": "0.0.1"})
      )

    assert {:error, {:theme_mismatch, ^installed, _}} = SiteArchive.import(site, build_zip(older))
    assert Content.list_pages(site.id) == []
  end

  test "errors when the preview names no theme", %{site: site, theme: theme} do
    files = Map.put(preview_files(theme), "manifest.json", "{}")

    assert {:error, {:theme_mismatch, _installed, nil}} =
             SiteArchive.import(site, build_zip(files))
  end

  test "errors on an archive that is neither a preview nor a Hugo site", %{site: site} do
    zip = build_zip(%{"manifest.json" => "{}", "theme.css" => "body{}"})

    assert {:error, :unrecognized_site} = SiteArchive.import(site, zip)
  end
end
