defmodule MastheadWeb.ViewTracker do
  @moduledoc """
  Records a public page view in `Masthead.Stats` once the response is known to
  be a 200, skipping bots and browsers carrying the member opt-out cookie.

  The visitor is a SHA-256 over the endpoint secret, the UTC date, the site,
  the client IP and the user agent: stable for a day, then unlinkable, and
  never stored in the clear.

  Members opt out by opening their site through `opt_out_url/1` (the admin
  "View site" link), which sets a host-only cookie on the tenant host — the
  login session is host-only on the admin host, so it can't be seen there.
  """
  @behaviour Plug

  import Plug.Conn

  alias Masthead.Stats

  @opt_out_cookie "masthead_no_track"
  @opt_out_salt "stats-opt-out"
  @opt_out_max_age 60 * 60 * 24 * 7
  @bot_pattern ~r/bot|crawl|spider|slurp|curl|wget|python|headless|preview|facebookexternalhit|monitor|http-client|okhttp|go-http/i

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &record/1)

  defp record(%Plug.Conn{status: 200} = conn) do
    conn = fetch_cookies(conn)
    ua = user_agent(conn)

    unless bot?(ua) or Map.has_key?(conn.req_cookies, @opt_out_cookie) do
      site_id = conn.assigns.current_site.id
      Stats.record_view(site_id, view_path(conn), visitor_hash(conn, site_id, ua))
    end

    conn
  end

  defp record(conn), do: conn

  defp bot?(nil), do: true
  defp bot?(ua), do: Regex.match?(@bot_pattern, ua)

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  defp view_path(conn), do: "/" <> Enum.join(conn.path_info, "/")

  defp visitor_hash(conn, site_id, ua) do
    :crypto.hash(:sha256, [
      MastheadWeb.Endpoint.config(:secret_key_base),
      Date.to_iso8601(Date.utc_today()),
      Integer.to_string(site_id),
      client_ip(conn),
      ua
    ])
  end

  defp client_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc "The site's public URL through the opt-out endpoint, for its members."
  def opt_out_url(site) do
    token = Phoenix.Token.sign(MastheadWeb.Endpoint, @opt_out_salt, site.id)
    Masthead.Sites.public_url(site) <> "/_masthead/no-track?t=" <> token
  end

  @doc "Sets the opt-out cookie when `token` was minted for `site`."
  def opt_out(conn, site, token) do
    case Phoenix.Token.verify(MastheadWeb.Endpoint, @opt_out_salt, token,
           max_age: @opt_out_max_age
         ) do
      {:ok, site_id} when site_id == site.id -> put_opt_out_cookie(conn)
      _ -> conn
    end
  end

  defp put_opt_out_cookie(conn) do
    put_resp_cookie(conn, @opt_out_cookie, "1",
      max_age: 60 * 60 * 24 * 365 * 5,
      http_only: true,
      same_site: "Lax"
    )
  end
end
