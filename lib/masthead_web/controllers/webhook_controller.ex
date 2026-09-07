defmodule MastheadWeb.WebhookController do
  @moduledoc """
  Payment provider webhooks.

  The caller is the provider, not a browser, so the route runs through no
  pipeline: no session, and no `:protect_from_forgery` to reject it. The raw
  body it was signed over is cached by `MastheadWeb.CacheBodyReader`.

  Register the endpoint against a bare app host. `MastheadWeb.SiteDispatcher`
  hands any host that resolves to a site over to `PublicRouter` before the
  main router ever sees the request.

  A bad signature answers 400 so the provider stops retrying garbage; an event
  we deliberately ignore answers 200 so it stops retrying that too.
  """
  use MastheadWeb, :controller

  require Logger

  alias Masthead.Licenses

  def payments(conn, _params) do
    case Licenses.handle_webhook(conn.assigns[:raw_body] || "", conn.req_headers) do
      :ok -> send_resp(conn, 200, "")
      {:ok, _site} -> send_resp(conn, 200, "")
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp reject(conn, reason) do
    Logger.warning("payment webhook rejected: #{inspect(reason)}")
    send_resp(conn, 400, "")
  end
end
