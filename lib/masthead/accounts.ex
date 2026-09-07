defmodule Masthead.Accounts do
  import Ecto.Query

  alias Masthead.Query
  alias Masthead.Repo
  alias Masthead.Accounts.User
  alias Masthead.Accounts.UserToken
  alias Masthead.Accounts.UserNotification
  alias Masthead.Accounts.UserNotifier
  alias Masthead.Accounts.UserIdentity
  alias Masthead.Sites
  alias Masthead.Storage

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Registers a user who accepted a site invitation. The account starts
  confirmed (the invite email proved control of the address).
  """
  def register_invited_user(attrs) do
    %User{}
    |> User.invited_registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Email tokens

  @doc """
  Builds a token for `user` in `context`, persists its hash, and returns
  the raw token to embed in an email link.
  """
  def generate_email_token(%User{} = user, context) do
    {raw_token, user_token} = UserToken.build_email_token(user, context)
    Repo.insert!(user_token)
    raw_token
  end

  @doc """
  Resolves a raw token to its user if the token is valid, the right
  context, and not expired. Returns `nil` otherwise.
  """
  def get_user_by_token(raw_token, context)
      when is_binary(raw_token) and is_binary(context) do
    case UserToken.verify_email_token_query(raw_token, context) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def get_user_by_token(_, _), do: nil

  @doc """
  Deletes `user`'s tokens. `contexts` is a list of context strings or
  `:all`. Used to make tokens single-use and to revoke on disable.
  """
  def delete_user_tokens(%User{} = user, contexts) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, contexts))
  end

  ## Email confirmation

  @doc """
  Sends a confirmation link. `url_fun` turns a raw token into the full
  confirmation URL. No-op (`{:error, :already_confirmed}`) if the email
  is already confirmed.
  """
  def deliver_user_confirmation_instructions(%User{} = user, url_fun)
      when is_function(url_fun, 1) do
    if User.confirmed?(user) do
      {:error, :already_confirmed}
    else
      token = generate_email_token(user, "confirm")
      UserNotifier.deliver_confirmation_instructions(user, url_fun.(token))
    end
  end

  @doc """
  Confirms the account behind `token`. Marks the email confirmed and
  burns every outstanding confirm token (single-use). `:error` if the
  token is invalid or expired.
  """
  def confirm_user(token) when is_binary(token) do
    with %User{} = user <- get_user_by_token(token, "confirm"),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts_query(user, ["confirm"])
    )
    # Confirming makes this account a verified member, which can bring a site
    # (disabled for lack of one) back online.
    |> Ecto.Multi.run(:sites, fn _repo, _ ->
      {:ok, Sites.reenable_recovered_sites_for_user(user.id)}
    end)
  end

  ## Password reset

  @doc "Changeset for the set-new-password form."
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  @doc """
  Sends a reset link. `url_fun` turns a raw token into the full URL.
  Callers must keep this enumeration-safe (don't reveal whether the
  address exists).
  """
  def deliver_user_reset_password_instructions(%User{} = user, url_fun)
      when is_function(url_fun, 1) do
    token = generate_email_token(user, "reset_password")
    UserNotifier.deliver_reset_password_instructions(user, url_fun.(token))
  end

  @doc "User behind a valid, unexpired reset token, or nil."
  def get_user_by_reset_password_token(token) when is_binary(token) do
    get_user_by_token(token, "reset_password")
  end

  @doc """
  Sets a new password. Reaching here proves control of the email, so we
  also confirm the account (if not already) and revoke every token so
  outstanding reset/confirm links die.
  """
  def reset_user_password(%User{} = user, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> maybe_confirm()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  defp maybe_confirm(changeset) do
    case changeset.data do
      %User{confirmed_at: nil} ->
        Ecto.Changeset.put_change(
          changeset,
          :confirmed_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )

      _ ->
        changeset
    end
  end

  ## Profile

  @avatar_namespace "avatars"
  @avatar_extensions ~w(.png .jpg .jpeg .gif .webp)

  @doc """
  Updates the public profile — the display name shown on the marketplace and
  in the live tracker, plus an optional new avatar (a `%Plug.Upload{}`). The
  replaced avatar file is removed once the row is saved.
  """
  def update_profile(%User{} = user, attrs, avatar) do
    case store_avatar(user, avatar) do
      {:ok, nil} ->
        save_profile(user, attrs)

      {:ok, path} ->
        user |> save_profile(Map.put(attrs, "avatar_path", path)) |> drop_avatar(user)

      {:error, _} = error ->
        error
    end
  end

  @doc "Public URL of the user's avatar, or nil when they have none."
  def avatar_url(%{avatar_path: path}) when is_binary(path), do: Storage.url(path)
  def avatar_url(_user), do: nil

  def change_user_profile(%User{} = user, attrs) do
    User.profile_changeset(user, attrs)
  end

  defp save_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  defp store_avatar(_user, %Plug.Upload{filename: ""}), do: {:ok, nil}

  defp store_avatar(user, %Plug.Upload{filename: filename, path: path}) do
    case String.downcase(Path.extname(filename)) do
      ext when ext in @avatar_extensions ->
        Storage.stream_into(@avatar_namespace, avatar_key(user, ext), path)

      _ ->
        {:error, :unsupported_image}
    end
  end

  defp store_avatar(_user, _not_an_upload), do: {:ok, nil}

  defp avatar_key(user, ext), do: "#{user.id}-#{System.system_time(:millisecond)}#{ext}"

  defp drop_avatar({:ok, _} = result, %User{avatar_path: old}) when is_binary(old) do
    _ = Storage.delete(old)
    result
  end

  defp drop_avatar(result, _user), do: result

  ## Password change (signed-in)

  @doc """
  Changes the password of a signed-in user, requiring the current
  password. `{:error, :invalid_current_password}` if it doesn't match.
  """
  def update_user_password(%User{} = user, current_password, attrs) do
    if User.valid_password?(user, current_password) do
      user
      |> User.password_changeset(attrs)
      |> Repo.update()
    else
      {:error, :invalid_current_password}
    end
  end

  ## Account disable / enable

  @doc """
  Soft-disables `user`: stamps `disabled_at`, takes offline any of their sites
  that are left with no verified member, and revokes all tokens. Idempotent.
  Re-enable via `enable_user/1`.

  Disabling an *unverified* user never changes a site's verified-member count,
  so the site cascade is skipped entirely — disabling an unconfirmed collaborator
  never takes a site offline.
  """
  def disable_user(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.disable_changeset(user))
    |> Ecto.Multi.run(:sites, fn _repo, _ ->
      if User.confirmed?(user) and is_nil(user.disabled_at) do
        {:ok, Sites.disable_orphaned_sites_for_user(user.id)}
      else
        {:ok, {0, nil}}
      end
    end)
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Opts the user out of onboarding/nudge emails (one-click unsubscribe).
  Idempotent; returns `:ok` whether or not the user exists.
  """
  def unsubscribe_onboarding_emails(user_id) do
    case Repo.get(User, user_id) do
      nil -> :ok
      user -> user |> User.onboarding_emails_changeset(false) |> Repo.update() && :ok
    end
  end

  @doc """
  Suspends accounts that never confirmed their email within `older_than_days`
  (default 30) of signing up, taking offline any of their sites left without a
  verified member. Unlike a disable this keeps the session/tokens intact so the
  user can log in and confirm (the verify gate pins them until they do). Skips
  already-disabled/suspended accounts. Returns the suspended users so the caller
  can send the "account suspended" email. Driven by
  `Masthead.Workers.SuspendUnconfirmed` on a daily cron.
  """
  def suspend_unconfirmed_accounts(older_than_days \\ 30) do
    stale =
      Repo.all(
        from u in User,
          where:
            is_nil(u.confirmed_at) and is_nil(u.disabled_at) and
              is_nil(u.suspended_at) and u.inserted_at < ^ago(older_than_days)
      )

    Enum.each(stale, &suspend_user/1)
    stale
  end

  defp suspend_user(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.suspend_changeset(user))
    |> Ecto.Multi.run(:sites, fn _repo, _ ->
      {:ok, Sites.disable_orphaned_sites_for_user(user.id)}
    end)
    |> Repo.transaction()
  end

  @doc """
  Unconfirmed, still-active accounts whose signup age is in `[min_days,
  max_days)` — the audience for a verify-or-lose-it warning email. Bounded so a
  backlog never fires the day-16 and day-23 warnings on the same run.
  """
  def unconfirmed_accounts_aged(min_days, max_days)
      when is_integer(min_days) and is_integer(max_days) do
    Repo.all(
      from u in User,
        where:
          is_nil(u.confirmed_at) and is_nil(u.disabled_at) and is_nil(u.suspended_at) and
            u.inserted_at <= ^ago(min_days) and u.inserted_at > ^ago(max_days)
    )
  end

  @doc """
  Active accounts ~2 weeks old that haven't signed in for over a week (or never
  since signup) and still want nudge emails — the day-14 "we miss you" audience.
  Sent regardless of verification status.
  """
  def accounts_due_for_login_reminder do
    week_ago = ago(7)

    Repo.all(
      from u in User,
        where:
          is_nil(u.disabled_at) and is_nil(u.suspended_at) and u.wants_onboarding_emails and
            u.inserted_at <= ^ago(14) and u.inserted_at > ^ago(16) and
            (is_nil(u.last_login_at) or u.last_login_at < ^week_ago)
    )
  end

  @doc """
  Enqueues the welcome email for `user`, at most once ever (guarded by the
  `user_notifications` sent-log). `sites_url` is the link into the admin.
  """
  def deliver_welcome(%User{} = user, sites_url) do
    notify_once(user.id, "welcome", fn -> UserNotifier.deliver_welcome(user, sites_url) end)
  end

  @doc """
  Runs `fun` exactly once per `(user_id, kind)`. The first call inserts the
  sent-log row and runs `fun`; later calls no-op (`:already_sent`). Used to make
  lifecycle emails idempotent across daily sweeps.
  """
  def notify_once(user_id, kind, fun) when is_function(fun, 0) do
    %UserNotification{}
    |> UserNotification.changeset(%{user_id: user_id, kind: kind})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :kind])
    |> case do
      {:ok, %UserNotification{id: id}} when not is_nil(id) ->
        fun.()
        :ok

      _ ->
        :already_sent
    end
  end

  defp ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 24 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end

  ## OAuth / SSO

  @doc """
  Resolves an OAuth login to a user. `info` is
  `%{provider, uid, email, email_verified}`.

    * known identity → that user
    * else, a verified email matching an existing account → link a new
      identity to it (account takeover is prevented by requiring the
      provider to vouch the email is verified)
    * else → create a fresh, already-confirmed account + identity

  Returns `{:ok, user}` or `{:error, :disabled | :no_email |
  :email_unverified}`.
  """
  def get_or_create_user_from_oauth(%{provider: provider, uid: uid} = info, opts \\ []) do
    provider = to_string(provider)
    uid = to_string(uid)

    case Repo.get_by(UserIdentity, provider: provider, provider_uid: uid) do
      %UserIdentity{} = identity ->
        return_if_active(Repo.preload(identity, :user).user)

      nil ->
        link_or_create(provider, uid, info, opts)
    end
  end

  defp link_or_create(provider, uid, %{email: email} = info, opts)
       when is_binary(email) and email != "" do
    case get_user_by_email(email) do
      %User{} = user ->
        cond do
          User.disabled?(user) -> {:error, :disabled}
          not Map.get(info, :email_verified, false) -> {:error, :email_unverified}
          true -> link_identity(user, provider, uid)
        end

      nil ->
        create_user_with_identity(email, provider, uid, opts)
    end
  end

  defp link_or_create(_provider, _uid, _info, _opts), do: {:error, :no_email}

  defp link_identity(user, provider, uid) do
    %UserIdentity{}
    |> UserIdentity.changeset(%{user_id: user.id, provider: provider, provider_uid: uid})
    |> Repo.insert(on_conflict: :nothing)

    {:ok, user}
  end

  defp create_user_with_identity(email, provider, uid, opts) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.oauth_registration_changeset(%User{}, %{email: email}))
    |> Ecto.Multi.insert(:identity, fn %{user: user} ->
      UserIdentity.changeset(%UserIdentity{}, %{
        user_id: user.id,
        provider: provider,
        provider_uid: uid
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        # OAuth accounts are confirmed on creation, so this is their only
        # welcome trigger. `on_create` lets the caller pass a route-built URL.
        if on_create = opts[:on_create], do: on_create.(user)
        {:ok, user}

      {:error, _, changeset, _} ->
        {:error, changeset}
    end
  end

  defp return_if_active(%User{} = user) do
    if User.disabled?(user), do: {:error, :disabled}, else: {:ok, user}
  end

  @doc """
  Re-enables a disabled account and restores its sites. Intended for
  console / admin use (there is no self-service re-enable).
  """
  def enable_user(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.enable_changeset(user))
    |> Ecto.Multi.run(:sites, fn _repo, _ ->
      {:ok, Sites.reenable_recovered_sites_for_user(user.id)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  # ---- admin ----

  @doc """
  Users for the admin overview, newest first, with optional filter +
  search. Capped at `count` rows — narrow with the filter + search rather
  than paging.
  """
  @sortable_users [:email, :confirmed_at, :disabled_at, :admin, :inserted_at, :last_login_at]

  def list_all_users(filter \\ :all, search_query \\ nil, count \\ 20, sort \\ nil) do
    from(u in User, order_by: [desc: u.inserted_at])
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Query.sort(sort, @sortable_users)
    |> limit(^count)
    |> Repo.all()
  end

  @doc "Total users matching the same filter + search, ignoring the row cap."
  def count_all_users(filter \\ :all, search_query \\ nil) do
    from(u in User)
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Repo.aggregate(:count)
  end

  defp apply_filter(query, filter) do
    case filter do
      :verified -> from u in query, where: not is_nil(u.confirmed_at)
      :unverified -> from u in query, where: is_nil(u.confirmed_at)
      :disabled -> from u in query, where: not is_nil(u.disabled_at)
      :admins -> from u in query, where: u.admin == true
      _ -> query
    end
  end

  defp apply_search(query, search_query) do
    if search_query && search_query != "" do
      from u in query, where: ilike(u.email, ^"%#{search_query}%")
    else
      query
    end
  end

  @doc "Stamps the user's last successful login. Called from `UserAuth.log_in_user/3`."
  def record_login(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    user |> Ecto.Changeset.change(last_login_at: now) |> Repo.update()
  end

  @doc """
  Marks a user's email confirmed without a token (admin verify). Also lifts any
  suspension and brings back sites disabled for lack of a verified member.
  """
  def verify_user(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.run(:sites, fn _repo, _ ->
      {:ok, Sites.reenable_recovered_sites_for_user(user.id)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc "Grants or revokes platform-admin access (console / admin use)."
  def set_admin(%User{} = user, admin?) when is_boolean(admin?) do
    user |> User.admin_changeset(admin?) |> Repo.update()
  end
end
