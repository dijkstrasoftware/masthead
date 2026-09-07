defmodule MastheadWeb.PageController do
  use MastheadWeb, :controller

  alias Masthead.Licenses

  @meta_description "Masthead is an open-source, multi-tenant publishing platform for blogs and small business sites. Custom domains, Markdown or HTML, themes, and automatic HTTPS."

  @github_url "https://github.com/JoeriDijkstra/masthead"

  # Visible FAQ on the homepage and the FAQPage structured data are generated
  # from this single source so they always stay in sync (a requirement for
  # Google's FAQ rich results and a strong signal for AI answer engines).
  @faqs [
    {"What is Masthead?",
     "Masthead is an open-source, multi-tenant publishing platform for blogs and small business websites. Each site runs on its own subdomain or custom domain, with content written in Markdown or HTML."},
    {"Is Masthead free and open source?",
     "Yes. Masthead is open source and the full source is available on GitHub, so you can self-host it or audit exactly how it works."},
    {"Can I use my own domain?",
     "Yes. You can point any custom domain — apex or subdomain — at a Masthead site. TLS certificates are provisioned automatically and your site is served over HTTPS as soon as DNS resolves."},
    {"Do I need to know how to code?",
     "No. You can write posts and pages in Markdown without any coding. If you want full control over design, you can also write raw HTML and upload custom themes."},
    {"Can I run more than one site?",
     "Yes. You can run unlimited sites from a single account, each with its own content, theme, and domain, all managed from one dashboard."}
  ]

  @pricing_description "Masthead is free to publish on: unlimited posts and pages, marketplace themes, and a masthead.site subdomain with automatic HTTPS. A paid site license adds your own custom domain and collaborators."

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
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> assign(:page_title, "Open-source publishing for blogs & small business sites")
        |> assign(:og_title, "Masthead — open-source publishing for blogs & small business sites")
        |> assign(:meta_description, @meta_description)
        |> assign(:canonical_url, url(~p"/"))
        |> assign(:og_image, url(~p"/images/logo.png"))
        |> assign(:faqs, @faqs)
        |> assign(:json_ld, home_json_ld())
        |> render(:home)

      _user ->
        redirect(conn, to: "/sites")
    end
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
