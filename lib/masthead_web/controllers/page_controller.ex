defmodule MastheadWeb.PageController do
  use MastheadWeb, :controller

  alias Masthead.{Features, Licenses}

  @meta_description "Masthead is the layer between a website and its owner. A theme declares what can be managed; Masthead builds the admin from it and hosts the site. Open source."

  @github_url "https://github.com/dijkstrasoftware/masthead"

  # Visible FAQ on the homepage and the FAQPage structured data are generated
  # from this single source so they always stay in sync (a requirement for
  # Google's FAQ rich results and a strong signal for AI answer engines).
  @faqs [
    {"What is Masthead?",
     "Masthead is the layer between a website and the person who manages it. A website's theme declares what its owner can change; Masthead turns that declaration into the site's admin and runs the site: hosting, domains, content storage and publishing."},
    {"How is Masthead different from WordPress?",
     "A WordPress theme changes how a site looks inside an admin that stays the same, and new capabilities arrive as plugins. A Masthead theme also defines the admin: which settings exist, which fields posts and pages carry, and which page types can be created. There are no plugins, so the owner sees what the theme exposes and nothing else."},
    {"Can I build my own theme?",
     "Yes. Start from the starter template, write the templates in Liquid, describe the settings in manifest.json and upload the zip. Keep it for your own sites or publish it to the marketplace."},
    {"Do I need to know how to code?",
     "Not to manage a site: owners write in Markdown, or HTML if they prefer, and fill in the fields their theme provides. Building a theme takes HTML, CSS and Liquid."},
    {"Can an agency use Masthead for client websites?",
     "That is one of the cases it's designed for. Build the theme, decide exactly what the client can change, connect their domain and invite them to the site. The client gets an admin that contains their website and nothing else. Custom domains, collaborators and statistics come with a site license."},
    {"Can I use my own domain?",
     "Yes, with a site license. Point the domain at Masthead and it verifies ownership and provisions the TLS certificate. Every site also gets a free masthead.site subdomain with HTTPS."}
  ]

  @pricing_description "Masthead is free to publish on: unlimited posts and pages, marketplace themes, and a masthead.site subdomain with automatic HTTPS. A paid site license adds your own custom domain, collaborators and visitor statistics."

  def pricing(conn, _params) do
    conn
    |> assign(:page_title, "Pricing")
    |> assign(:og_title, "Masthead pricing — free to publish, paid for your own domain")
    |> assign(:meta_description, @pricing_description)
    |> assign(:canonical_url, url(~p"/pricing"))
    |> assign(:og_image, url(~p"/images/logo.png"))
    |> assign(:free_price, Licenses.format(0))
    |> assign(:monthly_price, Licenses.format(Licenses.amount("monthly")))
    |> assign(:yearly_price, Licenses.format(Licenses.amount("yearly")))
    |> assign(:saving, Licenses.yearly_saving() && Licenses.format(Licenses.yearly_saving()))
    |> assign(:json_ld, pricing_json_ld())
    |> render(:pricing)
  end

  def home(conn, _params) do
    cond do
      conn.assigns[:current_user] ->
        redirect(conn, to: "/sites")

      not Features.enabled?("homepage") ->
        redirect(conn, to: ~p"/login")

      true ->
        conn
        |> assign(:page_title, "The website defines its own CMS")
        |> assign(:og_title, "Masthead — the website defines its own CMS")
        |> assign(:meta_description, @meta_description)
        |> assign(:canonical_url, url(~p"/"))
        |> assign(:og_image, url(~p"/images/logo.png"))
        |> assign(:faqs, @faqs)
        |> assign(:json_ld, home_json_ld())
        |> render(:home)
    end
  end

  def seo_file(conn, _params) do
    conn
    |> put_resp_content_type(MIME.from_path(conn.request_path))
    |> send_file(200, Application.app_dir(:masthead, "priv/static" <> conn.request_path))
  end

  # The standalone Themes section was folded into the Marketplace hub.
  # Keep the old URL working for bookmarks.
  def themes_redirect(conn, _params) do
    redirect(conn, to: "/marketplace/my-themes")
  end

  defp pricing_json_ld do
    currency = String.upcase(Licenses.currency())

    [
      %{
        "@context" => "https://schema.org",
        "@type" => "Product",
        "name" => "Masthead site license",
        "description" => @pricing_description,
        "url" => url(~p"/pricing"),
        "brand" => %{"@type" => "Brand", "name" => "Masthead"},
        "offers" =>
          Enum.map(Licenses.plans(), fn {name, plan} ->
            %{
              "@type" => "Offer",
              "name" => String.capitalize(name),
              "price" => :erlang.float_to_binary(plan.amount / 100, decimals: 2),
              "priceCurrency" => currency,
              "url" => url(~p"/pricing")
            }
          end)
      }
    ]
  end

  defp home_json_ld do
    home = url(~p"/")
    logo = url(~p"/images/logo.png")

    [
      %{
        "@context" => "https://schema.org",
        "@type" => "Organization",
        "name" => "Masthead",
        "url" => home,
        "logo" => logo,
        "sameAs" => [@github_url]
      },
      %{
        "@context" => "https://schema.org",
        "@type" => "WebSite",
        "name" => "Masthead",
        "url" => home
      },
      %{
        "@context" => "https://schema.org",
        "@type" => "SoftwareApplication",
        "name" => "Masthead",
        "applicationCategory" => "Content management system",
        "operatingSystem" => "Web",
        "url" => home,
        "description" => @meta_description,
        "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
      },
      %{
        "@context" => "https://schema.org",
        "@type" => "FAQPage",
        "mainEntity" =>
          Enum.map(@faqs, fn {question, answer} ->
            %{
              "@type" => "Question",
              "name" => question,
              "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
            }
          end)
      }
    ]
  end
end
