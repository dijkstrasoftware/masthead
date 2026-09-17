defmodule Masthead.Themes.ManifestTest do
  use ExUnit.Case, async: true
  alias Masthead.Themes.Manifest

  describe "parse/1" do
    test "accepts a minimal valid manifest" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[]})

      assert {:ok, %Manifest{name: "X", slug: "x", version: "1.0.0", tokens: []}} =
               Manifest.parse(json)
    end

    test "accepts tokens of every supported type" do
      json = """
      {"name":"X","slug":"x","version":"1.0.0","tokens":[
        {"key":"a","label":"A","type":"color","default":"#fff"},
        {"key":"b","label":"B","type":"string","default":"Inter"},
        {"key":"c","label":"C","type":"length","default":"4rem"},
        {"key":"d","label":"D","type":"number","default":"4"},
        {"key":"e","label":"E","type":"file","default":""},
        {"key":"f","label":"F","type":"select","options":["a","b"],"default":"a"}
      ]}
      """

      assert {:ok, %Manifest{tokens: tokens}} = Manifest.parse(json)
      assert length(tokens) == 6
    end

    test "tokens preserve an optional category" do
      json = """
      {"name":"X","slug":"x","version":"1.0.0","tokens":[
        {"key":"a","label":"A","type":"color","default":"#fff","category":"Header"},
        {"key":"b","label":"B","type":"string","default":""}
      ]}
      """

      assert {:ok, %Manifest{tokens: [a, b]}} = Manifest.parse(json)
      assert a.category == "Header"
      assert b.category == nil
    end

    test "select tokens require a non-empty options list" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0",) <>
          ~s("tokens":[{"key":"k","label":"K","type":"select","default":"a"}]})

      assert {:error, errors} = Manifest.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "tokens[0].options"))
    end

    test "rejects invalid JSON" do
      assert {:error, [msg]} = Manifest.parse("not json")
      assert msg =~ "invalid JSON"
    end

    test "collects every validation failure" do
      json = ~s({"slug":"Bad Slug","tokens":[{"type":"weird"}]})
      {:error, errors} = Manifest.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
      assert Enum.any?(errors, &String.contains?(&1, "version"))
      assert Enum.any?(errors, &String.contains?(&1, "slug"))
      assert Enum.any?(errors, &String.contains?(&1, "tokens[0].key"))
      assert Enum.any?(errors, &String.contains?(&1, "tokens[0].type"))
    end
  end

  describe "effective_tokens/2" do
    setup do
      {:ok, m} =
        Manifest.parse(~s({
          "name":"X","slug":"x","version":"1.0.0",
          "tokens":[
            {"key":"accent","label":"Accent","type":"color","default":"#fff"},
            {"key":"width","label":"Width","type":"length","default":"800px"}
          ]
        }))

      {:ok, manifest: m}
    end

    test "falls back to manifest defaults when no overrides", %{manifest: m} do
      assert %{"accent" => "#fff", "width" => "800px"} = Manifest.effective_tokens(m, %{})
    end

    test "overrides win over defaults", %{manifest: m} do
      assert %{"accent" => "#000", "width" => "800px"} =
               Manifest.effective_tokens(m, %{"accent" => "#000"})
    end

    test "empty-string override falls back to default", %{manifest: m} do
      assert %{"accent" => "#fff"} = Manifest.effective_tokens(m, %{"accent" => ""})
    end

    test "unknown override keys are dropped", %{manifest: m} do
      out = Manifest.effective_tokens(m, %{"nope" => "x"})
      refute Map.has_key?(out, "nope")
    end

    test "object and list tokens merge against their nested schema" do
      {:ok, m} =
        Manifest.parse(~s({
          "name":"X","slug":"x","version":"1.0.0",
          "tokens":[
            {"key":"hero","label":"Hero","type":"object","fields":[
              {"key":"title","label":"T","type":"string","default":"Default title"},
              {"key":"boxed","label":"B","type":"boolean","default":true}]},
            {"key":"links","label":"Links","type":"list","fields":[
              {"key":"label","label":"L","type":"string","default":""},
              {"key":"url","label":"U","type":"url","default":"#"}]}
          ]
        }))

      # No overrides: the object fills its nested defaults, the list is empty.
      assert %{"hero" => %{"title" => "Default title", "boxed" => true}, "links" => []} =
               Manifest.effective_tokens(m, %{})

      # Overrides: each list item is merged against the nested schema, so an
      # unset subkey still arrives at the template with its default.
      tokens =
        Manifest.effective_tokens(m, %{
          "hero" => %{"title" => "Custom", "boxed" => "false"},
          "links" => [%{"label" => "Docs", "url" => "/docs"}, %{"label" => "Blog"}]
        })

      assert tokens["hero"] == %{"title" => "Custom", "boxed" => false}

      assert tokens["links"] == [
               %{"label" => "Docs", "url" => "/docs"},
               %{"label" => "Blog", "url" => "#"}
             ]
    end

    test "a list token's declared default items apply when there is no override" do
      {:ok, m} =
        Manifest.parse(~s({
          "name":"X","slug":"x","version":"1.0.0",
          "tokens":[
            {"key":"links","label":"Links","type":"list",
             "default":[{"label":"Home"}],
             "fields":[
               {"key":"label","label":"L","type":"string","default":""},
               {"key":"url","label":"U","type":"url","default":"/"}]}
          ]
        }))

      assert Manifest.effective_tokens(m, %{}) == %{
               "links" => [%{"label" => "Home", "url" => "/"}]
             }

      # A stored empty list is a deliberate "no items", not "unset".
      assert Manifest.effective_tokens(m, %{"links" => []}) == %{"links" => []}
    end
  end

  describe "page option schema parsing" do
    test "accepts all supported field types" do
      json = """
      {"name":"X","slug":"x","version":"1.0.0","tokens":[],
       "page_options":[
         {"key":"s","label":"S","type":"string","default":""},
         {"key":"t","label":"T","type":"text","default":""},
         {"key":"b","label":"B","type":"boolean","default":false},
         {"key":"c","label":"C","type":"color","default":"#fff"},
         {"key":"u","label":"U","type":"url","default":""},
         {"key":"n","label":"N","type":"number","default":0},
         {"key":"sel","label":"Sel","type":"select","options":["a","b"],"default":"a"}
       ]}
      """

      assert {:ok, %Manifest{page_options: fields}} = Manifest.parse(json)
      assert length(fields) == 7
    end

    test "select fields require a non-empty options list" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],
                 "page_options":[{"key":"sel","label":"S","type":"select","default":"a"}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "options"))
    end

    test "default is required for every field" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],
                 "page_options":[{"key":"k","label":"K","type":"string"}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "default"))
    end

    test "unknown type is rejected" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],
                 "page_options":[{"key":"k","label":"K","type":"weird","default":""}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "type:"))
    end

    test "missing page_options key is fine (defaults to empty list)" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[]})
      assert {:ok, %Manifest{page_options: []}} = Manifest.parse(json)
    end
  end

  describe "page option defaults and coercion" do
    setup do
      {:ok, m} =
        Manifest.parse(~s({
          "name":"X","slug":"x","version":"1.0.0","tokens":[],
          "page_options":[
            {"key":"layout","label":"L","type":"select","options":["a","b"],"default":"a"},
            {"key":"hero","label":"H","type":"url","default":""},
            {"key":"hide","label":"D","type":"boolean","default":false},
            {"key":"count","label":"C","type":"number","default":0}
          ]
        }))

      {:ok, manifest: m}
    end

    test "falls back to declared defaults", %{manifest: m} do
      assert %{
               "layout" => "a",
               "hero" => "",
               "hide" => false,
               "count" => 0
             } = Manifest.merge_fields(m.page_options, %{})
    end

    test "overrides win", %{manifest: m} do
      assert %{"layout" => "b", "hero" => "/x.jpg"} =
               Manifest.merge_fields(m.page_options, %{"layout" => "b", "hero" => "/x.jpg"})
    end

    test "booleans coerce from form strings", %{manifest: m} do
      assert %{"hide" => true} = Manifest.merge_fields(m.page_options, %{"hide" => "true"})
      assert %{"hide" => false} = Manifest.merge_fields(m.page_options, %{"hide" => "false"})
    end

    test "numbers coerce from form strings", %{manifest: m} do
      assert %{"count" => 42} = Manifest.merge_fields(m.page_options, %{"count" => "42"})
      assert %{"count" => 3.5} = Manifest.merge_fields(m.page_options, %{"count" => "3.5"})
    end

    test "unknown override keys are preserved (theme-switch resilience)", %{manifest: m} do
      out = Manifest.merge_fields(m.page_options, %{"from_old_theme" => "still here"})
      assert out["from_old_theme"] == "still here"
    end
  end

  describe "field type parity (tokens and options share one type set)" do
    test "page options accept a file field (same as a token)" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],) <>
          ~s("page_options":[{"key":"hero","label":"Hero","type":"file","default":""}]})

      assert {:ok, %Manifest{page_options: [%{key: "hero", type: "file"}]}} = Manifest.parse(json)
    end

    test "a page config accepts a file field" do
      json = ~s({"page_options":[{"key":"img","label":"Image","type":"file","default":""}]})
      assert {:ok, %{page_options: [%{type: "file"}]}} = Manifest.parse_page_config(json)
    end

    test "tokens accept text and url types (same as options)" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[) <>
          ~s({"key":"bio","label":"Bio","type":"text","default":""},) <>
          ~s({"key":"link","label":"Link","type":"url","default":""}]})

      assert {:ok, %Manifest{tokens: [%{type: "text"}, %{type: "url"}]}} = Manifest.parse(json)
    end

    test "an unknown field type is rejected for both" do
      assert {:error, errs} =
               Manifest.parse(
                 ~s({"name":"X","slug":"x","version":"1.0.0",) <>
                   ~s("tokens":[{"key":"k","label":"K","type":"weird","default":""}]})
               )

      assert Enum.any?(errs, &String.contains?(&1, "tokens[0].type"))
    end

    test "tokens accept object and list containers (same as options)" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[) <>
          ~s({"key":"hero","label":"Hero","type":"object","fields":[) <>
          ~s({"key":"title","label":"T","type":"string","default":"Hi"}]},) <>
          ~s({"key":"links","label":"Links","type":"list","item_label":"Link","fields":[) <>
          ~s({"key":"url","label":"U","type":"url","default":""}]}]})

      assert {:ok, %Manifest{tokens: [hero, links]}} = Manifest.parse(json)
      assert hero.type == "object"
      assert [%{key: "title", type: "string"}] = hero.fields
      assert links.type == "list"
      assert links.item_label == "Link"
      assert [%{key: "url", type: "url"}] = links.fields
    end

    test "a container token requires a non-empty fields list, and can't nest a container" do
      assert {:error, errs} =
               Manifest.parse(
                 ~s({"name":"X","slug":"x","version":"1.0.0",) <>
                   ~s("tokens":[{"key":"hero","label":"H","type":"object"}]})
               )

      assert Enum.any?(errs, &String.contains?(&1, "tokens[0].fields"))

      assert {:error, errs} =
               Manifest.parse(
                 ~s({"name":"X","slug":"x","version":"1.0.0",) <>
                   ~s("tokens":[{"key":"hero","label":"H","type":"object","fields":[) <>
                   ~s({"key":"inner","label":"I","type":"list","fields":[]}]}]})
               )

      assert Enum.any?(errs, &String.contains?(&1, "tokens[0].fields[0].type"))
    end
  end

  describe "parse_page_config/1" do
    test "parses a label, description, and page option fields" do
      json = """
      {"label":"About","description":"The about page",
       "page_options":[
         {"key":"layout","label":"L","type":"select","options":["a","b"],"default":"a"},
         {"key":"show_footer","label":"F","type":"boolean","default":true}
       ]}
      """

      assert {:ok, config} = Manifest.parse_page_config(json)
      assert config.label == "About"
      assert config.description == "The about page"
      assert [%{key: "layout"}, %{key: "show_footer"}] = config.page_options
    end

    test "label, description and page options are all optional" do
      assert {:ok, %{label: nil, description: nil, page_options: []}} =
               Manifest.parse_page_config("{}")
    end

    test "rejects invalid JSON" do
      assert {:error, [msg]} = Manifest.parse_page_config("not json")
      assert msg =~ "invalid JSON"
    end

    test "rejects a non-string label" do
      assert {:error, errors} = Manifest.parse_page_config(~s({"label":123}))
      assert Enum.any?(errors, &String.contains?(&1, "label"))
    end

    test "validates each page option field (invalid type / select without options)" do
      json =
        ~s({"page_options":[) <>
          ~s({"key":"a","label":"A","type":"weird","default":"x"},) <>
          ~s({"key":"b","label":"B","type":"select","default":"x"}]})

      assert {:error, errors} = Manifest.parse_page_config(json)
      assert Enum.any?(errors, &String.contains?(&1, "page_options[0].type"))
      assert Enum.any?(errors, &String.contains?(&1, "page_options[1].options"))
    end
  end

  describe "object/list (nested) field types" do
    test "parses an object field with nested fields" do
      json = ~s({"page_options":[{"key":"hero","label":"Hero","type":"object","fields":[
        {"key":"title","label":"T","type":"string","default":"Hi"},
        {"key":"image","label":"I","type":"file","default":""}]}]})

      assert {:ok, %{page_options: [field]}} = Manifest.parse_page_config(json)
      assert field.type == "object"
      assert [%{key: "title"}, %{key: "image", type: "file"}] = field.fields
    end

    test "parses a list field with item_label and nested fields" do
      json = ~s({"page_options":[{"key":"crew","label":"Crew","type":"list","item_label":"Member",
        "default":[],"fields":[{"key":"name","label":"N","type":"string","default":""}]}]})

      assert {:ok, %{page_options: [field]}} = Manifest.parse_page_config(json)
      assert field.type == "list"
      assert field.item_label == "Member"
      assert [%{key: "name"}] = field.fields
    end

    test "a container requires a non-empty fields list" do
      assert {:error, errs} =
               Manifest.parse_page_config(
                 ~s({"page_options":[{"key":"x","label":"X","type":"object"}]})
               )

      assert Enum.any?(errs, &String.contains?(&1, "page_options[0].fields"))
    end

    test "containers cannot nest other containers (one level only)" do
      json = ~s({"page_options":[{"key":"x","label":"X","type":"object","fields":[
        {"key":"y","label":"Y","type":"list","fields":[]}]}]})

      assert {:error, errs} = Manifest.parse_page_config(json)
      assert Enum.any?(errs, &String.contains?(&1, "page_options[0].fields[0].type"))
    end

    test "a nested scalar still needs a default" do
      json = ~s({"page_options":[{"key":"x","label":"X","type":"object","fields":[
        {"key":"y","label":"Y","type":"string"}]}]})

      assert {:error, errs} = Manifest.parse_page_config(json)
      assert Enum.any?(errs, &String.contains?(&1, "page_options[0].fields[0].default"))
    end

    test "merge_fields recurses into objects and lists" do
      {:ok, %{page_options: fields}} =
        Manifest.parse_page_config(~s({"page_options":[
          {"key":"hero","label":"H","type":"object","fields":[
            {"key":"title","label":"T","type":"string","default":"Default title"},
            {"key":"on","label":"O","type":"boolean","default":true}]},
          {"key":"crew","label":"C","type":"list","fields":[
            {"key":"name","label":"N","type":"string","default":""}]}
        ]}))

      # No overrides → object fills nested defaults, list is empty.
      assert %{"hero" => %{"title" => "Default title", "on" => true}, "crew" => []} =
               Manifest.merge_fields(fields, %{})

      # Overrides: object subkey + list of items (each filled per nested schema).
      merged =
        Manifest.merge_fields(fields, %{
          "hero" => %{"title" => "Custom", "on" => "false"},
          "crew" => [%{"name" => "Ada"}, %{}]
        })

      assert merged["hero"] == %{"title" => "Custom", "on" => false}
      assert merged["crew"] == [%{"name" => "Ada"}, %{"name" => ""}]
    end

    test "a list's default items render when there is no override" do
      {:ok, %{page_options: fields}} =
        Manifest.parse_page_config(~s({"page_options":[
          {"key":"stats","label":"S","type":"list","default":[
            {"value":"30+","label":"Years"},{"value":"0","label":"Sales"}],
           "fields":[
             {"key":"value","label":"V","type":"string","default":""},
             {"key":"label","label":"L","type":"string","default":""}]}
        ]}))

      assert %{"stats" => [%{"value" => "30+", "label" => "Years"}, %{"value" => "0"}]} =
               Manifest.merge_fields(fields, %{})

      # An explicit empty-list override wins over the defaults.
      assert %{"stats" => []} = Manifest.merge_fields(fields, %{"stats" => []})
    end
  end

  describe "merge_fields/2" do
    setup do
      {:ok, config} =
        Manifest.parse_page_config(~s({
          "page_options":[
            {"key":"layout","label":"L","type":"select","options":["contained","wide"],"default":"contained"},
            {"key":"show_nav","label":"N","type":"boolean","default":true}
          ]
        }))

      {:ok, fields: config.page_options}
    end

    test "applies defaults, coercion, and preserves unknown keys", %{fields: fields} do
      assert %{"layout" => "contained", "show_nav" => true} = Manifest.merge_fields(fields, %{})

      assert %{"layout" => "wide", "show_nav" => false} =
               Manifest.merge_fields(fields, %{"layout" => "wide", "show_nav" => "false"})

      assert %{"legacy" => "kept"} = Manifest.merge_fields(fields, %{"legacy" => "kept"})
    end

    test "an empty field list yields just the preserved overrides" do
      assert %{"x" => "1"} = Manifest.merge_fields([], %{"x" => "1"})
    end
  end

  describe "render_version" do
    test "defaults to beta when the manifest omits it" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[]})
      assert {:ok, %Manifest{render_version: "beta"}} = Manifest.parse(json)
    end

    test "accepts a known version" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","render_version":"v1","tokens":[]})
      assert {:ok, %Manifest{render_version: "v1"}} = Manifest.parse(json)
    end

    test "rejects an unknown version" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","render_version":"v99","tokens":[]})
      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "render_version"))
    end
  end

  describe "structured_data" do
    test "defaults to on and accepts an opt-out" do
      assert {:ok, %Manifest{structured_data: true}} =
               Manifest.parse(~s({"name":"X","slug":"x","version":"1.0.0","tokens":[]}))

      assert {:ok, %Manifest{structured_data: false}} =
               Manifest.parse(
                 ~s({"name":"X","slug":"x","version":"1.0.0","structured_data":false,"tokens":[]})
               )
    end

    test "rejects a non-boolean" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","structured_data":"no","tokens":[]})
      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "structured_data"))
    end
  end

  describe "legacy metadata key (beta themes)" do
    test "parses into page_options" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],) <>
          ~s("metadata":[{"key":"layout","label":"L","type":"string","default":"a"}]})

      assert {:ok, %Manifest{render_version: "beta", page_options: [%{key: "layout"}]}} =
               Manifest.parse(json)
    end

    test "a page config's metadata parses into page_options" do
      json = ~s({"metadata":[{"key":"img","label":"Image","type":"file","default":""}]})
      assert {:ok, %{page_options: [%{key: "img"}]}} = Manifest.parse_page_config(json)
    end

    test "errors are reported under the key the manifest actually used" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],) <>
          ~s("metadata":[{"key":"k","label":"K","type":"weird","default":""}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "metadata[0].type"))
    end
  end

  describe "post_options" do
    test "parse with the same field types as page options" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","render_version":"v1","tokens":[],) <>
          ~s("post_options":[) <>
          ~s({"key":"featured_image","label":"F","type":"file","default":""},) <>
          ~s({"key":"crew","label":"C","type":"list","fields":[) <>
          ~s({"key":"name","label":"N","type":"string","default":""}]}]})

      assert {:ok, %Manifest{post_options: [%{key: "featured_image", type: "file"}, list_field]}} =
               Manifest.parse(json)

      assert list_field.type == "list"
    end

    test "default to an empty list" do
      json = ~s({"name":"X","slug":"x","version":"1.0.0","render_version":"v1","tokens":[]})
      assert {:ok, %Manifest{post_options: []}} = Manifest.parse(json)
    end

    test "are rejected on a beta theme, whose renderer can't expose them" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","tokens":[],) <>
          ~s("post_options":[{"key":"f","label":"F","type":"file","default":""}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "post_options"))
    end

    test "invalid fields are reported under the post_options prefix" do
      json =
        ~s({"name":"X","slug":"x","version":"1.0.0","render_version":"v1","tokens":[],) <>
          ~s("post_options":[{"key":"f","label":"F","type":"weird","default":""}]})

      assert {:error, errs} = Manifest.parse(json)
      assert Enum.any?(errs, &String.contains?(&1, "post_options[0].type"))
    end
  end

  describe "option_fields/2" do
    test "reads string-keyed, atom-keyed and legacy persisted manifests" do
      declared = [%{"key" => "layout", "label" => "L", "type" => "string", "default" => ""}]

      assert Manifest.option_fields(%{"page_options" => declared}, :page_options) == declared
      assert Manifest.option_fields(%{page_options: declared}, :page_options) == declared
      assert Manifest.option_fields(%{"metadata" => declared}, :page_options) == declared
      assert Manifest.option_fields(%{"post_options" => declared}, :post_options) == declared
    end

    test "is empty for a manifest that declares nothing" do
      assert Manifest.option_fields(%{}, :page_options) == []
      assert Manifest.option_fields(nil, :post_options) == []
    end
  end
end
