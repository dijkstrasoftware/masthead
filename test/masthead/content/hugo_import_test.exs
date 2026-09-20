defmodule Masthead.Content.HugoImportTest do
  use Masthead.DataCase, async: true

  alias Masthead.{Accounts, Content, Sites, Themes, Uploads}
  alias Masthead.Content.SiteArchive

  setup do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "hugo-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "hugo#{System.unique_integer([:positive])}",
        "name" => "Hugo Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    %{site: site}
  end

  # Writes `files` (relpath => content) under a tmp dir and zips them up.
  defp build_zip(files) do
    base = Path.join(System.tmp_dir!(), "hugo-src-#{System.unique_integer([:positive])}")

    for {rel, content} <- files do
      abs = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end

    zip = Path.join(System.tmp_dir!(), "hugo-#{System.unique_integer([:positive])}.zip")
    rels = files |> Map.keys() |> Enum.map(&String.to_charlist/1)
    {:ok, _} = :zip.create(String.to_charlist(zip), rels, cwd: String.to_charlist(base))

    on_exit(fn ->
      File.rm_rf(base)
      File.rm(zip)
    end)

    zip
  end

  @first_post """
  ---
  title: "My First Post"
  draft: false
  ---
  Here is an image: ![logo](/images/logo.png)

  {{< figure src="/images/logo.png" alt="Logo" >}}

  See [the second post](/posts/second-post/) for more.
  """

  @second_post """
  +++
  title = "Second Post"
  draft = true
  +++
  Still cooking.
  """

  @about_page """
  ---
  title: "About Us"
  ---
  Who we are.
  """

  defp sample_files do
    %{
      "content/posts/first-post.md" => @first_post,
      "content/posts/second-post.md" => @second_post,
      "content/about.md" => @about_page,
      "content/_index.md" => "---\ntitle: Home\n---\nSection index.",
      "static/images/logo.png" => "fake-png-bytes",
      "static/css/site.css" => "body{}",
      "themes/mytheme/layouts/index.html" => "ignored",
      "config.toml" => "baseURL = 'https://example.com'"
    }
  end

  test "imports posts, pages and assets, ignoring theme and section index", %{site: site} do
    {:ok, summary} = SiteArchive.import(site, build_zip(sample_files()))

    assert length(summary.posts) == 2
    assert length(summary.pages) == 1
    assert summary.uploads == 1
    assert summary.skipped_assets == 1
    # `_index.md` is skipped as a section index, the css as an unsupported asset.
    assert {"_index.md", :section_index} in summary.skipped_content

    posts = Content.list_posts(site.id) |> Map.new(&{&1.title, &1})
    assert posts["My First Post"].published == true
    # Hugo's default slug is the filename, not the title.
    assert posts["My First Post"].slug == "first-post"
    assert posts["Second Post"].published == false

    pages = Content.list_pages(site.id)
    assert [%{title: "About Us"} = about] = pages
    # Imported pages follow the normal default — shown in nav.
    assert about.show_in_nav == true

    assert [%{filename: "logo.png"}] = Uploads.list_uploads(site.id)
  end

  test "rewrites asset URLs, figure shortcodes and trailing slashes", %{site: site} do
    {:ok, _summary} = SiteArchive.import(site, build_zip(sample_files()))

    body =
      Content.list_posts(site.id) |> Enum.find(&(&1.title == "My First Post")) |> Map.get(:body)

    [upload] = Uploads.list_uploads(site.id)
    upload_url = Uploads.url(upload)

    # The static path is replaced with the new upload URL.
    assert body =~ upload_url
    refute body =~ "/images/logo.png"

    # The figure shortcode became a Markdown image.
    assert body =~ "![Logo](#{upload_url})"
    refute body =~ "{{<"

    # The internal link lost its trailing slash to match Masthead URLs.
    assert body =~ "](/posts/second-post)"
    refute body =~ "/posts/second-post/"
  end

  test "errors when the archive has no content directory", %{site: site} do
    zip = build_zip(%{"static/x.png" => "bytes", "config.toml" => "x = 1"})
    assert {:error, :unrecognized_site} = SiteArchive.import(site, zip)
  end

  test "finds the Hugo root when nested one directory down", %{site: site} do
    files = %{
      "my-site/content/posts/hello.md" => "---\ntitle: Hello\ndraft: false\n---\nHi",
      "my-site/config.toml" => "x = 1"
    }

    {:ok, summary} = SiteArchive.import(site, build_zip(files))
    assert length(summary.posts) == 1
  end
end
