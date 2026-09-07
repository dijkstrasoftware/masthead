defmodule MastheadWeb.AccountHTML do
  use MastheadWeb, :html

  alias Masthead.Accounts.User
  alias MastheadWeb.AdminLive.Components

  attr :user, :map, required: true
  attr :profile_changeset, :map, required: true
  attr :password_changeset, :map, required: true

  def show(assigns) do
    ~H"""
    <Components.shell title="Account" current_user={@user} flash={@flash}>
      <div class="wizard">
        <div class="form settings-form">
          <section class="settings-section">
            <header class="settings-section-head">
              <h2>Personal details</h2>
              <p>The email you sign in with and where account email is sent.</p>
            </header>

            <div class="settings-fields account-fields">
              <div class="account-row">
                <div>
                  <div class="account-row-label">Email</div>
                  <div class="account-row-value">{@user.email}</div>
                </div>
                <span class={["pill", (User.confirmed?(@user) && "pill-live") || "pill-draft"]}>
                  {(User.confirmed?(@user) && "Confirmed") || "Not confirmed"}
                </span>
              </div>

              <form :if={not User.confirmed?(@user)} action={~p"/confirm"} method="post">
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <button type="submit" class="btn">Resend confirmation email</button>
              </form>
            </div>
          </section>

          <section class="settings-section">
            <header class="settings-section-head">
              <h2>Profile</h2>
              <p>How you appear on the marketplace and to others viewing a site with you.</p>
            </header>

            <div class="settings-fields account-fields">
              <form
                action={~p"/account/profile"}
                method="post"
                enctype="multipart/form-data"
                class="account-form"
              >
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <.error_list changeset={@profile_changeset} />

                <div class="account-profile-preview">
                  <Components.user_avatar user={@user} class="user-avatar account-avatar" />
                  <label>
                    Profile picture
                    <input
                      type="file"
                      name="avatar"
                      accept="image/png,image/jpeg,image/gif,image/webp"
                    />
                  </label>
                </div>

                <label>
                  Display name
                  <input
                    type="text"
                    name="user[display_name]"
                    value={@user.display_name}
                    required
                    minlength="2"
                    maxlength="40"
                  />
                </label>
                <button type="submit" class="btn btn-primary">Save profile</button>
              </form>
            </div>
          </section>

          <section class="settings-section">
            <header class="settings-section-head">
              <h2>Security</h2>
              <p>Change your password or disable your account.</p>
            </header>

            <div class="settings-fields account-fields">
              <form action={~p"/account/password"} method="post" class="account-form">
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <.error_list changeset={@password_changeset} />
                <label>
                  Current password <input type="password" name="current_password" required />
                </label>
                <label>
                  New password (min 8 chars)
                  <input type="password" name="user[password]" required minlength="8" />
                </label>
                <button type="submit" class="btn btn-primary">Update password</button>
              </form>

              <hr class="account-divider" />

              <div class="account-row">
                <div>
                  <div class="account-row-label">Disable account</div>
                  <p class="muted account-hint">
                    Disables your account and takes all of your sites offline immediately.
                    You won't be able to sign back in, and this can't be undone here.
                  </p>
                </div>
                <form
                  action={~p"/account/disable"}
                  method="post"
                  onsubmit="return confirm('Disable your account and take all your sites offline? You will be logged out and cannot undo this yourself.');"
                >
                  <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                  <button type="submit" class="btn btn-danger">Disable my account</button>
                </form>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Components.shell>
    """
  end

  attr :changeset, :map, required: true

  # Only after a submit (changeset has an action) — never on first load.
  defp error_list(assigns) do
    ~H"""
    <ul :if={@changeset.action && @changeset.errors != []} class="errors">
      <li :for={{field, {msg, opts}} <- @changeset.errors}>{field}: {interpolate(msg, opts)}</li>
    </ul>
    """
  end

  defp interpolate(msg, opts) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
