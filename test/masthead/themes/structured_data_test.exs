defmodule Masthead.Themes.StructuredDataTest do
  use ExUnit.Case, async: true

  alias Masthead.Themes.StructuredData

  @site %{name: "Bakery", title: "", description: ""}
  @base "https://bakery.example"

  test "website drops blank optional fields and falls back to the site name" do
    data = StructuredData.website(@site, @base)

    assert data["@type"] == "WebSite"
    assert data["name"] == "Bakery"
    assert data["url"] == "https://bakery.example/"
    refute Map.has_key?(data, "description")
  end

  test "article omits dates it doesn't have" do
    post = %{title: "Rye", slug: "rye", excerpt: nil, published_at: nil, updated_at: nil}
    data = StructuredData.article(@site, post, @base)

    assert data["headline"] == "Rye"
    assert data["mainEntityOfPage"] == "https://bakery.example/posts/rye"
    refute Map.has_key?(data, "datePublished")
    refute Map.has_key?(data, "description")
    refute Map.has_key?(data, "author")
  end

  describe "inject/3" do
    @data %{"name" => "</script><b>"}
    @manifest %{structured_data: true}

    test "puts the script before a case-insensitive </head>" do
      html = StructuredData.inject("<HEAD><title>x</title></HEAD><body></body>", @data, @manifest)

      assert html =~ ~r{</title><script type="application/ld\+json">.*</script></HEAD><body>}
    end

    test "escapes markup inside the JSON" do
      html = StructuredData.inject("<head></head>", @data, @manifest)

      refute html =~ "</script><b>"
      assert html =~ ~S(</script>)
    end

    test "appends when the layout has no head" do
      assert StructuredData.inject("<p>x</p>", @data, @manifest) =~
               ~r{^<p>x</p><script type="application/ld\+json">}
    end

    test "leaves the html alone without data or when the theme opts out" do
      assert StructuredData.inject("<head></head>", nil, @manifest) == "<head></head>"

      assert StructuredData.inject("<head></head>", @data, %{structured_data: false}) ==
               "<head></head>"
    end
  end
end
