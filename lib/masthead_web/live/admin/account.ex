defmodule MastheadWeb.AdminLive.Account do
  @moduledoc """
  The signed-in user's own account page: their public profile (avatar +
  display name, both edited in place) and their security settings.

  Changing the password opens a dialog rather than sitting on the page —
  it's a rare, deliberate act, not a field you scroll past. Disabling the
  account stays a plain form post: it clears the session, which a LiveView
  can't do.
  """
  use MastheadWeb, :live_view

  import MastheadWeb.AdminLive.Components

  alias Masthead.Accounts
  alias Masthead.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Account",
       editing_name?: false,
       password_open?: false,
       password_error: nil,
       upload_error: nil
     )
     |> assign_name_form()
     |> allow_upload(:avatar,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 1,
       max_file_size: 8_000_000,
       auto_upload: true,
       progress: &store_avatar/3
     )}
  end

  # ---- display name (inline) ----

  @impl true
  def handle_event("edit_name", _params, socket) do
    {:noreply, assign(socket, editing_name?: true)}
  end

  def handle_event("cancel_name", _params, socket) do
    {:noreply, socket |> assign(editing_name?: false) |> assign_name_form()}
  end

  def handle_event("save_name", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(current_user: user, editing_name?: false)
         |> assign_name_form()
         |> put_flash(:info, "That's how you'll show up from now on.")}

      {:error, changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset, action: :validate))}
    end
  end

  # ---- avatar ----

  def handle_event("validate_avatar", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  # ---- password (dialog) ----

  def handle_event("open_password", _params, socket) do
    {:noreply, assign(socket, password_open?: true, password_error: nil)}
  end

  def handle_event("close_password", _params, socket) do
    {:noreply, assign(socket, password_open?: false, password_error: nil)}
  end

  def handle_event("save_password", params, socket) do
    %{"current_password" => current, "user" => attrs} = params

    case Accounts.update_user_password(socket.assigns.current_user, current, attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(password_open?: false, password_error: nil)
         |> put_flash(:info, "Password updated.")}

      {:error, :invalid_current_password} ->
        {:noreply, assign(socket, password_error: "Current password is incorrect.")}

      {:error, changeset} ->
        {:noreply, assign(socket, password_error: first_error(changeset))}
    end
  end

  # Auto-upload: the picture is the change, so it saves the moment it lands
  # rather than waiting for a submit button that has nothing else to do.
  defp store_avatar(:avatar, %{done?: false}, socket), do: {:noreply, socket}

  defp store_avatar(:avatar, _entry, socket) do
    user = socket.assigns.current_user
    [result] = consume_uploaded_entries(socket, :avatar, &save_avatar(user, &1, &2))
    apply_avatar(result, socket)
  end

  # Storing happens inside the consume callback: LiveView deletes the temp
  # file the moment it returns.
  defp save_avatar(user, %{path: path}, entry) do
    {:ok, Accounts.update_avatar(user, %{filename: entry.client_name, path: path})}
  end

  defp apply_avatar({:ok, user}, socket) do
    {:noreply,
     socket
     |> assign(current_user: user)
     |> put_flash(:info, "Profile picture updated.")}
  end

  defp apply_avatar({:error, _reason}, socket) do
    {:noreply, assign(socket, upload_error: "That picture couldn't be saved. Try another one.")}
  end

  # No `phx-change` counterpart on purpose: the name is checked when it's
  # submitted, not while it's half-typed.
  defp assign_name_form(socket) do
    assign(socket, name_form: to_form(Accounts.change_user_profile(socket.assigns.current_user)))
  end

  defp first_error(%Ecto.Changeset{errors: [{field, {msg, _}} | _]}), do: "#{field} #{msg}"
  defp first_error(_changeset), do: "That password couldn't be saved."

  @impl true
  def render(assigns) do
    ~H"""
    <.shell title="Account" current_user={@current_user} flash={@flash}>
      <div class="wizard">
        <div class="form settings-form">
          <section class="settings-section">
            <header class="settings-section-head">
              <h2>Profile</h2>
              <p>How you appear on the marketplace and to anyone viewing a site with you.</p>
            </header>

            <div class="settings-fields account-fields">
              <div class="profile-identity">
                <form id="avatar-upload" phx-change="validate_avatar">
                  <label
                    id="avatar-dropzone"
                    class="profile-avatar-picker"
                    phx-hook="ImageCompress"
                    data-max-dim="512"
                    phx-drop-target={@uploads.avatar.ref}
                    title="Change your profile picture"
                  >
                    <.user_avatar user={@current_user} class="user-avatar profile-avatar" />
                    <input type="file" accept="image/*" class="js-image-picker" />
                    <.live_file_input upload={@uploads.avatar} />
                    <span class="profile-avatar-overlay" aria-hidden="true">
                      <.camera_icon />
                    </span>
                    <span class="visually-hidden">Change your profile picture</span>
                  </label>
                </form>

                <div class="profile-lines">
                  <div :if={not @editing_name?} class="profile-name-row">
                    <span class="profile-name">{@current_user.display_name}</span>
                    <button
                      type="button"
                      class="card-icon-btn"
                      phx-click="edit_name"
                      title="Edit display name"
                      aria-label="Edit display name"
                    >
                      <.pencil_icon />
                    </button>
                  </div>

                  <.form
                    :if={@editing_name?}
                    for={@name_form}
                    phx-submit="save_name"
                    class="profile-name-form"
                  >
                    <input
                      type="text"
                      id={@name_form[:display_name].id}
                      name={@name_form[:display_name].name}
                      value={@name_form[:display_name].value}
                      maxlength="40"
                      autofocus
                    />
                    <button type="submit" class="btn btn-sm btn-primary">Save</button>
                    <button type="button" class="btn btn-sm" phx-click="cancel_name">Cancel</button>
                  </.form>

                  <p :for={{msg, _} <- @name_form[:display_name].errors} class="error">
                    Display name {msg}
                  </p>

                  <span class="profile-email">{@current_user.email}</span>
                </div>

                <span class={[
                  "pill",
                  "profile-pill",
                  (User.confirmed?(@current_user) && "pill-live") || "pill-draft"
                ]}>
                  {(User.confirmed?(@current_user) && "Confirmed") || "Not confirmed"}
                </span>
              </div>

              <p :if={@upload_error} class="error">{@upload_error}</p>
              <p :for={err <- upload_errors(@uploads.avatar)} class="error">
                {upload_error_message(err)}
              </p>

              <form :if={not User.confirmed?(@current_user)} action={~p"/confirm"} method="post">
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <button type="submit" class="btn">Resend confirmation email</button>
              </form>
            </div>
          </section>

          <section class="settings-section">
            <header class="settings-section-head">
              <h2>Security</h2>
              <p>Change your password or disable your account.</p>
            </header>

            <div class="settings-fields account-fields">
              <div class="account-row">
                <div>
                  <div class="account-row-label">Password</div>
                  <p class="muted account-hint">
                    You'll need your current password to set a new one.
                  </p>
                </div>
                <button type="button" class="btn" phx-click="open_password">
                  Change password
                </button>
              </div>

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

      <div
        :if={@password_open?}
        class="dialog-backdrop"
        phx-window-keydown="close_password"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_password"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>Change password</h2>
            <button type="button" phx-click="close_password" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <form phx-submit="save_password" class="dialog-form" id="password-form">
            <p :if={@password_error} class="error">{@password_error}</p>

            <label>
              Current password <input type="password" name="current_password" required autofocus />
            </label>

            <label>
              New password <input type="password" name="user[password]" required minlength="8" />
              <small>At least 8 characters.</small>
            </label>

            <footer class="dialog-footer">
              <button type="button" phx-click="close_password" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Update password</button>
            </footer>
          </form>
        </div>
      </div>
    </.shell>
    """
  end

  defp upload_error_message(:too_large), do: "That picture is too large (8 MB max)."
  defp upload_error_message(:not_accepted), do: "Pick a png, jpg, gif or webp."
  defp upload_error_message(_error), do: "That picture couldn't be uploaded."
end
