defmodule MastheadWeb.Attribution do
  @moduledoc """
  First-touch acquisition cookie for signed-out visitors. Stores only the UTM
  params, whether a `gclid` was present, the landing path, an external referrer
  host and the first-seen time — never the IP, user agent, full URL or `gclid`
  value. Signup copies it onto the user (`user_attrs/1`) and deletes it.
  """
  import Plug.Conn

  @cookie "_mh_attr"
  @max_age 30 * 24 * 60 * 60

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])

    if Map.has_key?(conn.cookies, @cookie) do
      conn
    else
      put_resp_cookie(conn, @cookie, capture(fetch_query_params(conn)),
        sign: true,
        max_age: @max_age,
        same_site: "Lax",
        http_only: true
      )
    end
  end

  @doc "The cookie as user attributes; `%{}` when absent (channel stays Unknown)."
  def user_attrs(conn) do
    case fetch_cookies(conn, signed: [@cookie]).cookies[@cookie] do
      %{} = attrs -> Map.update(attrs, :first_seen_at, nil, &parse_time/1)
      _ -> %{}
    end
  end

  def delete(conn), do: delete_resp_cookie(conn, @cookie)

  defp capture(conn) do
    params = conn.query_params

    %{
      utm_source: clean(params["utm_source"]),
      utm_medium: clean(params["utm_medium"]),
      utm_campaign: clean(params["utm_campaign"]),
      gclid_present: clean(params["gclid"]) != nil,
      landing_path: String.slice(conn.request_path, 0, 255),
      referrer_domain: referrer_domain(conn),
      first_seen_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> Map.reject(fn {_, v} -> v in [nil, false] end)
  end

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> String.slice(v, 0, 100)
    end
  end

  defp clean(_), do: nil

  defp referrer_domain(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(referer),
         host = String.downcase(host),
         false <- host in [conn.host | Application.get_env(:masthead, :app_hosts, [])] do
      host
    else
      _ -> nil
    end
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
