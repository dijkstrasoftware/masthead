defmodule Masthead.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :avatar_path, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :disabled_at, :utc_datetime
    field :suspended_at, :utc_datetime
    field :last_login_at, :utc_datetime
    field :wants_onboarding_emails, :boolean, default: true
    field :admin, :boolean, default: false
    # Populated only by `Sites.list_members/1` (the member's site-join time).
    field :joined_at, :utc_datetime, virtual: true

    has_many :tokens, Masthead.Accounts.UserToken
    has_many :memberships, Masthead.Sites.SiteMembership
    has_many :sites, through: [:memberships, :site]

    timestamps(type: :utc_datetime)
  end

  @display_name_max 40

  @doc "Email is confirmed."
  def confirmed?(%__MODULE__{confirmed_at: at}), do: not is_nil(at)

  @doc "Account is disabled (self-serve or auto-disabled)."
  def disabled?(%__MODULE__{disabled_at: at}), do: not is_nil(at)

  @doc """
  Account is suspended — an unconfirmed account that hit the 30-day cutoff.
  Unlike `disabled?/1` the user can still log in, but is pinned to the verify
  screen until they confirm.
  """
  def suspended?(%__MODULE__{suspended_at: at}), do: not is_nil(at)

  @doc "Platform admin (can manage all users/sites/themes)."
  def admin?(%__MODULE__{admin: admin}), do: admin == true

  @doc "Grants or revokes platform-admin access."
  def admin_changeset(user, admin?) when is_boolean(admin?) do
    change(user, admin: admin?)
  end

  @doc """
  Marks the email confirmed and clears any suspension (confirming is exactly
  what lifts a day-30 suspension). No-op effect if already confirmed.
  """
  def confirm_changeset(user) do
    change(user, confirmed_at: now(), suspended_at: nil)
  end

  @doc "Toggle the onboarding/nudge email opt-in (used by one-click unsubscribe)."
  def onboarding_emails_changeset(user, enabled?) when is_boolean(enabled?) do
    change(user, wants_onboarding_emails: enabled?)
  end

  @doc "Soft-disables the account."
  def disable_changeset(user) do
    change(user, disabled_at: now())
  end

  @doc "Clears the disabled flag (re-enable)."
  def enable_changeset(user) do
    change(user, disabled_at: nil)
  end

  @doc "Suspends the account (day-30 unconfirmed cutoff). Reversible by confirming."
  def suspend_changeset(user) do
    change(user, suspended_at: now())
  end

  @doc """
  Sets the public profile: the display name shown on the marketplace and in
  the live tracker, plus the storage path of an already-stored avatar.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :avatar_path])
    |> update_change(:display_name, &String.trim(&1 || ""))
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 2, max: @display_name_max)
    |> unsafe_validate_unique(:display_name, Masthead.Repo)
    |> unique_constraint(:display_name)
  end

  # The display name defaults to the email's local part. A taken one gets a
  # numeric suffix, so registration never fails on a name the user never chose.
  defp put_default_display_name(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :display_name, available_name(base_name(email)))
    end
  end

  defp base_name(email) do
    email |> String.split("@") |> hd() |> String.slice(0, @display_name_max - 3)
  end

  defp available_name(base), do: Enum.find_value(0..99, base, &free_name(base, &1))

  defp free_name(base, n) do
    name = if n == 0, do: base, else: "#{base}#{n}"
    if is_nil(Masthead.Repo.get_by(__MODULE__, display_name: name)), do: name
  end

  @doc "Sets a new password (password-reset flow)."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  @doc """
  Registers a user that authenticated via OAuth. The email is owned by
  the provider (and we only reach here for verified emails), so the
  account starts confirmed. A random password is set so password login
  is effectively disabled until the user resets it.
  """
  def oauth_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Masthead.Repo)
    |> unique_constraint(:email)
    |> put_default_display_name()
    |> put_change(:password, random_password())
    |> put_change(:confirmed_at, now())
    |> hash_password()
  end

  defp random_password, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 8, max: 72)
    |> unsafe_validate_unique(:email, Masthead.Repo)
    |> unique_constraint(:email)
    |> put_default_display_name()
    |> hash_password()
  end

  @doc """
  Registers a user who signed up by accepting a site invitation. Same as
  `registration_changeset/2` (the user chooses a real password) but the
  account starts confirmed — the invitation email already proved control of
  the address, so no confirmation step (and no 7-day auto-disable) applies.
  """
  def invited_registration_changeset(user, attrs) do
    user
    |> registration_changeset(attrs)
    |> put_change(:confirmed_at, now())
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      pw ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(pw))
        |> delete_change(:password)
    end
  end

  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
