defmodule Masthead.Themes.PackageTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Themes}
  alias Masthead.Themes.Package

  setup do
    # Built-ins must exist for slug-reservation checks.
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "package-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    %{user: user}
  end

  test "installs a valid theme zip end-to-end", %{user: user} do
    slug = "valid#{System.unique_integer([:positive])}"
    zip_path = build_zip(valid_files(slug))

    assert {:ok, theme} = Package.install(zip_path, user.id)
    assert theme.slug == slug
    assert theme.source == "uploaded"
    assert theme.owner_id == user.id

    File.rm(zip_path)
  end

  test "preserves token category and options in the persisted manifest", %{user: user} do
    slug = "tokens#{System.unique_integer([:positive])}"

    manifest =
      Jason.encode!(%{
        "name" => "Demo #{slug}",
        "slug" => slug,
        "version" => "1.0.0",
        "tokens" => [
          %{
            "key" => "header_style",
            "label" => "Header text color",
            "type" => "select",
            "default" => "dark",
            "options" => ["dark", "light"],
            "category" => "Header"
          }
        ]
      })

    files = valid_files(slug) |> Map.put("manifest.json", manifest)
    zip_path = build_zip(files)

    assert {:ok, theme} = Package.install(zip_path, user.id)
    assert [token] = theme.manifest["tokens"]
    assert token["category"] == "Header"
    assert token["options"] == ["dark", "light"]

    File.rm(zip_path)
  end

  test "rejects an archive that exceeds the size cap", %{user: user} do
    slug = "bloat#{System.unique_integer([:positive])}"
    # 26 MB of repeating chars compresses to a few KB but trips the 25 MB
    # uncompressed cap.
    junk = String.duplicate("x", 26 * 1024 * 1024)
    files = valid_files(slug) |> Map.put("theme.css", junk)
    zip_path = build_zip(files)

    assert {:error, reason} = Package.install(zip_path, user.id)

    assert match?({:archive_too_large, _, _}, reason) or
             match?({:uncompressed_too_large, _, _}, reason)

    File.rm(zip_path)
  end

  test "rejects a missing manifest", %{user: user} do
    slug = "nomanifest#{System.unique_integer([:positive])}"
    files = valid_files(slug) |> Map.delete("manifest.json")
    zip_path = build_zip(files)

    assert {:error, :manifest_missing} = Package.install(zip_path, user.id)
    File.rm(zip_path)
  end

  test "rejects a missing template", %{user: user} do
    slug = "notpl#{System.unique_integer([:positive])}"
    files = valid_files(slug) |> Map.delete("templates/post.liquid")
    zip_path = build_zip(files)

    assert {:error, {:template_missing, "post"}} = Package.install(zip_path, user.id)
    File.rm(zip_path)
  end

  test "rejects a slug reserved by a built-in", %{user: user} do
    zip_path = build_zip(valid_files("default"))

    assert {:error, {:slug_reserved, "default"}} = Package.install(zip_path, user.id)
    File.rm(zip_path)
  end

  test "rejects a syntactically invalid liquid template", %{user: user} do
    slug = "badtpl#{System.unique_integer([:positive])}"

    files =
      valid_files(slug)
      |> Map.put("templates/index.liquid", "{% if %}{% endfor %}")

    zip_path = build_zip(files)

    assert {:error, {:template_invalid, "index", _}} = Package.install(zip_path, user.id)
    File.rm(zip_path)
  end

  test "updates the existing theme in place when the version is newer", %{user: user} do
    slug = "upd#{System.unique_integer([:positive])}"

    z1 = build_zip(valid_files(slug) |> put_version("1.0.0"))
    assert {:ok, t1} = Package.install(z1, user.id)
    assert t1.version == "1.0.0"
    File.rm(z1)

    z2 = build_zip(valid_files(slug) |> put_version("1.1.0"))
    assert {:ok, t2} = Package.install(z2, user.id)
    File.rm(z2)

    assert t2.id == t1.id
    assert t2.version == "1.1.0"
  end

  test "rejects an upload whose version is not newer than the installed one", %{user: user} do
    slug = "same#{System.unique_integer([:positive])}"

    z1 = build_zip(valid_files(slug) |> put_version("2.0.0"))
    assert {:ok, _} = Package.install(z1, user.id)
    File.rm(z1)

    z_eq = build_zip(valid_files(slug) |> put_version("2.0.0"))

    assert {:error, {:version_not_newer, ^slug, "2.0.0", "2.0.0"}} =
             Package.install(z_eq, user.id)

    File.rm(z_eq)

    z_old = build_zip(valid_files(slug) |> put_version("1.9.0"))

    assert {:error, {:version_not_newer, ^slug, "2.0.0", "1.9.0"}} =
             Package.install(z_old, user.id)

    File.rm(z_old)
  end

  test "rejects updating when the uploaded version is not valid semver", %{user: user} do
    slug = "sem#{System.unique_integer([:positive])}"

    z1 = build_zip(valid_files(slug) |> put_version("1.0.0"))
    assert {:ok, _} = Package.install(z1, user.id)
    File.rm(z1)

    z2 = build_zip(valid_files(slug) |> put_version("banana"))
    assert {:error, {:version_unparseable, "banana"}} = Package.install(z2, user.id)
    File.rm(z2)
  end

  test "accepts a JavaScript asset in the theme bundle", %{user: user} do
    slug = "themejs#{System.unique_integer([:positive])}"

    files =
      valid_files(slug)
      |> Map.put("assets/app.js", "console.log('hello from the theme')")

    zip_path = build_zip(files)

    assert {:ok, _theme} = Package.install(zip_path, user.id)
    File.rm(zip_path)
  end

  test "installs page templates + sidecar configs and persists them", %{user: user} do
    files =
      valid_files("pages#{System.unique_integer([:positive])}")
      |> Map.put("templates/pages/blog.liquid", "<h1>{{ page.title | escape }}</h1>")
      |> Map.put("templates/pages/landing.liquid", "<main>Landing</main>")
      |> Map.put(
        "templates/pages/blog.json",
        Jason.encode!(%{
          "label" => "Blog",
          "page_options" => [%{"key" => "x", "label" => "X", "type" => "string", "default" => ""}]
        })
      )

    zip_path = build_zip(files)
    assert {:ok, theme} = Package.install(zip_path, user.id)
    assert Enum.sort(theme.manifest["page_templates"]) == ["blog", "landing"]
    # Only the page with a .json gets a config; its label + fields are persisted.
    assert %{"blog" => %{"label" => "Blog", "page_options" => [%{"key" => "x"}]}} =
             theme.manifest["page_configs"]

    refute Map.has_key?(theme.manifest["page_configs"], "landing")
  end

  test "installs and persists an object/list page config", %{user: user} do
    files =
      valid_files("nested#{System.unique_integer([:positive])}")
      |> Map.put("templates/pages/landing.liquid", "<h1>x</h1>")
      |> Map.put(
        "templates/pages/landing.json",
        Jason.encode!(%{
          "label" => "Landing",
          "page_options" => [
            %{
              "key" => "hero",
              "label" => "Hero",
              "type" => "object",
              "fields" => [
                %{"key" => "title", "label" => "T", "type" => "string", "default" => ""}
              ]
            },
            %{
              "key" => "crew",
              "label" => "Crew",
              "type" => "list",
              "item_label" => "Member",
              "default" => [],
              "fields" => [
                %{"key" => "name", "label" => "N", "type" => "string", "default" => ""}
              ]
            }
          ]
        })
      )

    zip_path = build_zip(files)
    assert {:ok, theme} = Package.install(zip_path, user.id)
    cfg = theme.manifest["page_configs"]["landing"]

    assert [%{"type" => "object", "fields" => [_]}, %{"type" => "list", "item_label" => "Member"}] =
             cfg["page_options"]
  end

  test "rejects a page config that nests a container inside a container", %{user: user} do
    files =
      valid_files("badnest#{System.unique_integer([:positive])}")
      |> Map.put("templates/pages/x.liquid", "<h1>x</h1>")
      |> Map.put(
        "templates/pages/x.json",
        Jason.encode!(%{
          "page_options" => [
            %{
              "key" => "a",
              "label" => "A",
              "type" => "object",
              "fields" => [%{"key" => "b", "label" => "B", "type" => "list", "fields" => []}]
            }
          ]
        })
      )

    zip_path = build_zip(files)
    assert {:error, {:page_config_invalid, "x", _}} = Package.install(zip_path, user.id)
  end

  test "rejects an invalid page config", %{user: user} do
    files =
      valid_files("badcfg#{System.unique_integer([:positive])}")
      |> Map.put("templates/pages/blog.liquid", "<h1>x</h1>")
      |> Map.put(
        "templates/pages/blog.json",
        Jason.encode!(%{"page_options" => [%{"key" => "k", "label" => "K", "type" => "weird"}]})
      )

    zip_path = build_zip(files)
    assert {:error, {:page_config_invalid, "blog", _}} = Package.install(zip_path, user.id)
  end

  test "no templates/pages folder yields an empty page_templates list", %{user: user} do
    zip_path = build_zip(valid_files("nopages#{System.unique_integer([:positive])}"))
    assert {:ok, theme} = Package.install(zip_path, user.id)
    assert theme.manifest["page_templates"] == []
  end

  test "a theme without templates/blog.liquid still installs (blog is optional)", %{user: user} do
    files =
      valid_files("noblog#{System.unique_integer([:positive])}")
      |> Map.delete("templates/blog.liquid")

    zip_path = build_zip(files)
    assert {:ok, _theme} = Package.install(zip_path, user.id)
  end

  test "rejects a syntactically invalid page template", %{user: user} do
    files =
      valid_files("badpage#{System.unique_integer([:positive])}")
      |> Map.put("templates/pages/broken.liquid", "{% if %}")

    zip_path = build_zip(files)
    assert {:error, {:page_template_invalid, "broken", _}} = Package.install(zip_path, user.id)
  end

  # ---- helpers ----

  defp put_version(files, version) do
    {:ok, m} = Jason.decode(files["manifest.json"])
    Map.put(files, "manifest.json", Jason.encode!(Map.put(m, "version", version)))
  end

  defp valid_files(slug) do
    %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Demo #{slug}",
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }
  end

  defp build_zip(files) do
    tmp =
      Path.join(System.tmp_dir!(), "theme-test-#{System.unique_integer([:positive])}.zip")

    entries =
      Enum.map(files, fn {name, body} -> {String.to_charlist(name), body} end)

    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end
end
