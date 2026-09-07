defmodule Masthead.Sites do
  import Ecto.Query
  alias Masthead.Licenses
  alias Masthead.Realtime
  alias Masthead.Query
  alias Masthead.Repo
  alias Masthead.Accounts
  alias Masthead.Accounts.User
  alias Masthead.Accounts.UserNotifier
  alias Masthead.Sites.{Site, SiteInvitation, SiteMembership}

  @doc "Non-deleted sites the user is a member of, alphabetical."
  def list_sites_for_user(user_id) do
    Repo.all(
      from s in Site,
        join: m in SiteMembership,
        on: m.site_id == s.id,
        where: m.user_id == ^user_id and is_nil(s.deleted_at),
        order_by: s.name
    )
  end

  def get_site!(id), do: Repo.get!(Site, id)

  def get_user_site!(user_id, id) do
    Repo.one!(
      from s in Site,
        join: m in SiteMembership,
        on: m.site_id == s.id,
        where: s.id == ^id and m.user_id == ^user_id and is_nil(s.deleted_at)
    )
  end

  def get_user_site_by_slug!(user_id, slug) do
    Repo.one!(
      from s in Site,
        join: m in SiteMembership,
        on: m.site_id == s.id,
        where: s.slug == ^slug and m.user_id == ^user_id and is_nil(s.deleted_at)
    )
  end

  @doc """
  Public resolver used by the Subdomain plug. Disabled or soft-deleted
  sites resolve to `nil` so the request 404s.
  """
  def get_site_by_slug(slug) when is_binary(slug) do
    Repo.one(
      from s in Site, where: s.slug == ^slug and is_nil(s.disabled_at) and is_nil(s.deleted_at)
    )
  end

  @doc """
  Resolves a site by an `active` custom domain. Only domains that have
  completed verification + cert issuance route traffic — a merely
  configured-but-not-active domain must not serve a site.
  """
  def get_site_by_custom_domain(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    Repo.one(
      from s in Site,
        where:
          s.custom_domain == ^host and
            s.custom_domain_status == "active" and
            is_nil(s.disabled_at) and
            is_nil(s.deleted_at)
    )
  end

  @doc """
  All custom domains currently serving traffic. Used to build the
  endpoint's dynamic `check_origin` allow-list.
  """
  def list_active_custom_domains do
    Repo.all(
      from s in Site,
        where:
          s.custom_domain_status == "active" and
            not is_nil(s.custom_domain) and
            is_nil(s.disabled_at) and
            is_nil(s.deleted_at),
        select: s.custom_domain
    )
  end

  # ---- admin ----

  @doc """
  Sites for the admin overview (incl. disabled/soft-deleted), with members
  preloaded. Capped at `count` rows — the overview is meant to be narrowed
  with the filter + search, not paged through.
  """
  @sortable_sites [:name, :slug, :inserted_at, :disabled_at]

  def list_all_sites(filter \\ :all, search_query \\ nil, count \\ 20, sort \\ nil) do
    from(s in Site, order_by: [desc: s.id])
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Query.sort(sort, @sortable_sites)
    |> limit(^count)
    |> Repo.all()
  end

  @doc "Total sites matching the same filter + search, ignoring the row cap."
  def count_all_sites(filter \\ :all, search_query \\ nil) do
    from(s in Site)
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Repo.aggregate(:count)
  end

  @doc "Load any site by slug for an admin entering it. Excludes soft-deleted."
  def get_site_for_admin_by_slug!(slug) when is_binary(slug) do
    Repo.one!(from s in Site, where: s.slug == ^slug and is_nil(s.deleted_at))
  end

  defp set_site_timestamp(%Site{} = site, field, value) do
    site |> Ecto.Changeset.change(%{field => value}) |> Repo.update()
  end

  @doc """
  Pauses a site manually from the console (stops resolving). Tagged
  `disabled_reason: "admin"` so the member-availability cascade never
  re-enables it. Reversible via `enable_site/1`.
  """
  def disable_site(%Site{} = site) do
    site
    |> Ecto.Changeset.change(disabled_at: truncated_now(), disabled_reason: "admin")
    |> Repo.update()
  end

  @doc "Un-pauses a site (admin)."
  def enable_site(%Site{} = site) do
    site
    |> Ecto.Changeset.change(disabled_at: nil, disabled_reason: nil)
    |> Repo.update()
  end

  @doc "Soft-deletes a site (hidden from owner + public; retained for recovery)."
  def soft_delete_site(%Site{} = site) do
    case set_site_timestamp(site, :deleted_at, truncated_now()) do
      {:ok, _} = result ->
        Realtime.site_gone(site.id)
        result

      other ->
        other
    end
  end

  @doc "Restores a soft-deleted site."
  def restore_site(%Site{} = site), do: set_site_timestamp(site, :deleted_at, nil)

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Auto-disables sites in `site_ids` that have **no verified member left**
  (verified = confirmed email and active account). Call this after a *verified*
  member is lost (disabled/suspended) — a site that still has a verified member
  stays online, and admin-paused / soft-deleted sites are untouched. Disabled
  rows are tagged `disabled_reason: "no_verified_member"` so `reenable_recovered_sites/1`
  can heal them later without resurrecting an admin pause.
  """
  def disable_orphaned_sites(site_ids) when is_list(site_ids) do
    keep = sites_with_verified_member(site_ids)
    orphaned = site_ids -- keep

    Repo.update_all(
      from(s in Site,
        where: s.id in ^orphaned and is_nil(s.disabled_at) and is_nil(s.deleted_at)
      ),
      set: [disabled_at: truncated_now(), disabled_reason: "no_verified_member"]
    )
  end

  @doc """
  Re-enables sites in `site_ids` that regained a verified member **and** were
  auto-disabled for lack of one (`disabled_reason == "no_verified_member"`).
  Call after a member is verified/enabled. Never touches admin-paused
  (`"admin"`) or soft-deleted sites.
  """
  def reenable_recovered_sites(site_ids) when is_list(site_ids) do
    recovered = sites_with_verified_member(site_ids)

    Repo.update_all(
      from(s in Site,
        where: s.id in ^recovered and s.disabled_reason == "no_verified_member"
      ),
      set: [disabled_at: nil, disabled_reason: nil]
    )
  end

  @doc "Auto-disable the sites of `user_id` that just lost their last verified member."
  def disable_orphaned_sites_for_user(user_id),
    do: user_id |> member_site_ids() |> Repo.all() |> disable_orphaned_sites()

  @doc "Re-enable the auto-disabled sites of `user_id` that regained a verified member."
  def reenable_recovered_sites_for_user(user_id),
    do: user_id |> member_site_ids() |> Repo.all() |> reenable_recovered_sites()

  # Site ids `user_id` is a member of.
  defp member_site_ids(user_id) do
    from m in SiteMembership, where: m.user_id == ^user_id, select: m.site_id
  end

  # Of `site_ids`, the ones with at least one verified member (confirmed +
  # active). These are the sites that should stay/become available.
  defp sites_with_verified_member(site_ids) do
    Repo.all(
      from m in SiteMembership,
        join: u in User,
        on: u.id == m.user_id,
        where:
          m.site_id in ^site_ids and not is_nil(u.confirmed_at) and
            is_nil(u.disabled_at),
        distinct: true,
        select: m.site_id
    )
  end

  @doc """
  Creates a site and its first membership (the creating `user`) in one
  transaction, then seeds the onboarding checklist.
  """
  def create_site(attrs, %User{id: user_id}), do: do_create_site(attrs, user_id)

  @doc """
  Convenience form used by seeds/tests: the creating user is taken from an
  `owner_id` key in `attrs`. Prefer `create_site/2`.
  """
  def create_site(attrs) do
    user_id =
      Map.get(attrs, "owner_id") || Map.get(attrs, :owner_id) ||
        raise ArgumentError, "create_site/1 needs an owner_id in attrs; prefer create_site/2"

    do_create_site(Map.drop(attrs, ["owner_id", :owner_id]), user_id)
  end

  defp do_create_site(attrs, user_id) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:site, Site.create_changeset(%Site{}, attrs_with_default_theme(attrs)))
      |> Ecto.Multi.insert(:membership, fn %{site: site} ->
        SiteMembership.changeset(%SiteMembership{}, %{site_id: site.id, user_id: user_id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{site: site}} ->
        maybe_create_onboarding_actions(site)
        {:ok, site}

      {:error, :site, changeset, _} ->
        {:error, changeset}

      {:error, :membership, changeset, _} ->
        {:error, changeset}
    end
  end

  # ---- memberships & invitations ----

  @doc "Users who are members of `site`, ordered by email."
  def list_members(%Site{} = site) do
    Repo.all(
      from u in User,
        join: m in SiteMembership,
        on: m.user_id == u.id,
        where: m.site_id == ^site.id,
        order_by: u.email,
        select_merge: %{joined_at: m.inserted_at}
    )
  end

  @doc "Number of members on the site."
  def count_members(site_id) do
    Repo.aggregate(from(m in SiteMembership, where: m.site_id == ^site_id), :count, :id)
  end

  @doc "Whether `user_id` is a member of `site_id`."
  def member?(site_id, user_id) do
    Repo.exists?(from m in SiteMembership, where: m.site_id == ^site_id and m.user_id == ^user_id)
  end

  @doc "Adds `user` to `site` (idempotent on the unique constraint)."
  def add_member(%Site{} = site, %User{} = user) do
    %SiteMembership{}
    |> SiteMembership.changeset(%{site_id: site.id, user_id: user.id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:site_id, :user_id])
    |> case do
      {:ok, _} = result ->
        Realtime.members_changed(site.id)
        result

      other ->
        other
    end
  end

  @doc """
  Removes `user` from `site`. Refuses (`{:error, :last_member}`) when it would
  leave the site with no members. `{:error, :not_member}` if `user` isn't one.
  """
  def remove_member(%Site{} = site, %User{} = user) do
    if count_members(site.id) <= 1 do
      {:error, :last_member}
    else
      {n, _} =
        Repo.delete_all(
          from m in SiteMembership, where: m.site_id == ^site.id and m.user_id == ^user.id
        )

      if n > 0 do
        Realtime.members_changed(site.id)
        Realtime.access_revoked(user.id, site.id)
        :ok
      else
        {:error, :not_member}
      end
    end
  end

  @doc "Pending invitations (unregistered emails) for `site`, ordered by email."
  def list_invitations(%Site{} = site) do
    Repo.all(from i in SiteInvitation, where: i.site_id == ^site.id, order_by: i.email)
  end

  @doc """
  Invites `email` to collaborate on `site`. If the email already has an
  account they are added immediately (`{:ok, :added}`) and notified; otherwise
  a fresh invitation is stored and a signup link is emailed (`{:ok,
  :invited}`). `url_fun` turns the raw token into the full `/invite/:token`
  URL. `{:error, :already_member | :invalid_email}` otherwise.

  Collaborators are a paid feature, so an unlicensed site gets
  `{:error, :requires_license}`.
  """
  def invite_to_site(%Site{} = site, email, url_fun) when is_function(url_fun, 1) do
    email = SiteInvitation.normalize_email(email)

    cond do
      not Licenses.paid?(site) ->
        {:error, :requires_license}

      not String.match?(email, ~r/^[^\s]+@[^\s]+$/) ->
        {:error, :invalid_email}

      user = Accounts.get_user_by_email(email) ->
        if member?(site.id, user.id) do
          {:error, :already_member}
        else
          {:ok, _} = add_member(site, user)
          UserNotifier.deliver_site_added_notification(user, site, site_admin_url(site))
          {:ok, :added}
        end

      true ->
        # Replace any stale pending invite so only the newest link is valid.
        {raw, invitation} = SiteInvitation.build(site.id, email)

        Repo.delete_all(
          from i in SiteInvitation, where: i.site_id == ^site.id and i.email == ^email
        )

        {:ok, _} = Repo.insert(invitation)
        UserNotifier.deliver_site_invitation(email, site, url_fun.(raw))
        Realtime.members_changed(site.id)
        {:ok, :invited}
    end
  end

  @doc "Loads a still-valid invitation (with its site) by raw token, or nil."
  def get_invitation_by_token(raw_token) when is_binary(raw_token) do
    case SiteInvitation.verify_token_query(raw_token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  @doc "Loads a site's invitation by id (for the cancel action)."
  def get_site_invitation!(%Site{} = site, id) do
    Repo.one!(from i in SiteInvitation, where: i.site_id == ^site.id and i.id == ^id)
  end

  @doc "Cancels a pending invitation."
  def delete_invitation(%SiteInvitation{} = invitation) do
    case Repo.delete(invitation) do
      {:ok, _} = result ->
        Realtime.members_changed(invitation.site_id)
        result

      other ->
        other
    end
  end

  @doc """
  Consumes `invitation` for a now-registered `user`: creates the membership
  and deletes the invitation (and any duplicate for the same email/site).
  Returns `{:ok, site_id}`.
  """
  def accept_invitation(%SiteInvitation{} = invitation, %User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :membership,
      SiteMembership.changeset(%SiteMembership{}, %{
        site_id: invitation.site_id,
        user_id: user.id
      }),
      on_conflict: :nothing,
      conflict_target: [:site_id, :user_id]
    )
    |> Ecto.Multi.delete_all(
      :invitations,
      from(i in SiteInvitation,
        where: i.site_id == ^invitation.site_id and i.email == ^invitation.email
      )
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} ->
        Realtime.members_changed(invitation.site_id)
        {:ok, invitation.site_id}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  # Admin URL for the site (the "you've been added" email links here).
  defp site_admin_url(%Site{slug: slug}), do: MastheadWeb.Endpoint.url() <> "/" <> slug

  # Seed the onboarding checklist for a freshly created site with the content
  # actions only. The "set description" nudge is staggered — it's added later,
  # once the site has its first post or page (see `Masthead.Actions`).
  defp maybe_create_onboarding_actions(%Site{} = site) do
    Masthead.Actions.create_action(site, "create_first_post")
    Masthead.Actions.create_action(site, "create_first_page")
    Masthead.Actions.create_action(site, "import_site")
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # Every site must have a theme_id (NOT NULL). The signup wizard doesn't
  # ask for one — sites start on the built-in "default" theme and can be
  # changed from the settings screen.
  defp attrs_with_default_theme(attrs) do
    has_theme? =
      Map.has_key?(attrs, "theme_id") or Map.has_key?(attrs, :theme_id)

    if has_theme? do
      attrs
    else
      case Masthead.Themes.get_built_in_by_slug("default") do
        nil -> attrs
        theme -> Map.put(attrs, "theme_id", theme.id)
      end
    end
  end

  def update_settings(%Site{} = site, attrs) do
    with {:ok, site} <-
           site
           |> Site.settings_changeset(attrs)
           |> Repo.update() do
      # Completing is idempotent, so it's safe to call on every save.
      unless blank?(site.description),
        do: Masthead.Actions.complete_action(site, "set_description")

      Realtime.settings_changed(site.id)
      {:ok, site}
    end
  end

  def change_site(%Site{} = site, attrs \\ %{}) do
    Site.create_changeset(site, attrs)
  end

  def change_settings(%Site{} = site, attrs \\ %{}) do
    Site.settings_changeset(site, attrs)
  end

  defp apply_filter(query, filter) do
    now = DateTime.utc_now()

    case filter do
      :disabled ->
        from s in query, where: not is_nil(s.disabled_at)

      :deleted ->
        from s in query, where: not is_nil(s.deleted_at)

      :enabled ->
        from s in query, where: is_nil(s.disabled_at) and is_nil(s.deleted_at)

      :paid ->
        from s in query,
          where: s.license_status in ~w(active canceling) and s.license_expires_at > ^now

      :free ->
        from s in query,
          where:
            is_nil(s.license_status) or s.license_status not in ~w(active canceling) or
              is_nil(s.license_expires_at) or s.license_expires_at <= ^now

      _ ->
        query
    end
  end

  defp apply_search(query, search_query) do
    if search_query && search_query != "" do
      from s in query, where: ilike(s.name, ^"%#{search_query}%")
    else
      query
    end
  end
end
