defmodule MastheadWeb.AdminLive.Checklist do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.Actions

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site

    {:ok,
     socket
     |> assign(
       page_title: "Checklist — #{site.name}",
       todo_form: nil
     )
     |> assign_actions()}
  end

  @impl true
  def handle_event("dismiss_action", %{"key" => key}, socket) do
    :ok = Actions.dismiss_action(socket.assigns.site, key)
    {:noreply, assign_actions(socket)}
  end

  def handle_event("open_todo_modal", _params, socket) do
    {:noreply, assign(socket, todo_form: to_form(%{}))}
  end

  def handle_event("change_todo", params, socket) do
    {:noreply, assign(socket, todo_form: to_form(params))}
  end

  def handle_event("close_todo_modal", _params, socket) do
    {:noreply, assign(socket, todo_form: nil)}
  end

  def handle_event("create_todo", params, socket) do
    case Actions.create_custom_action(socket.assigns.site, params) do
      {:ok, _action} ->
        {:noreply,
         socket
         |> assign(todo_form: nil)
         |> put_flash(:info, "Todo added.")
         |> assign_actions()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(todo_form: to_form(params))
         |> put_flash(:error, error_message(changeset))}
    end
  end

  @impl true
  def handle_info({:realtime, :actions}, socket), do: {:noreply, assign_actions(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_actions(socket) do
    actions = Actions.list_pending(socket.assigns.site)
    assign(socket, actions: actions, action_count: length(actions))
  end

  defp message_length(form), do: String.length(form[:message].value || "")

  defp error_message(%{errors: [{:path, {message, _}} | _]}), do: "Link #{message}."

  defp error_message(_changeset), do: "Add a title (max 80) and a short description (max 200)."

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Checklist"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:checklist}
      action_count={@action_count}
      present_users={@present_users}
    >
      <:actions>
        <button
          id="new-todo"
          type="button"
          phx-click="open_todo_modal"
          class="btn btn-primary btn-add"
        >
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New todo</span>
        </button>
      </:actions>

      <div :if={@actions == []} class="empty-state empty-state-illustrated">
        <img
          src={~p"/images/illustrations/empty-checklist.svg"}
          alt=""
          class="empty-illustration"
        />
        <h2>You're all caught up</h2>
        <p>There are no outstanding actions for this site.</p>
      </div>

      <div :if={@actions != []} class="action-list">
        <.action_card :for={action <- @actions} action={action} />
      </div>

      <div
        :if={@todo_form}
        class="dialog-backdrop"
        phx-window-keydown="close_todo_modal"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_todo_modal"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>New todo</h2>
            <button
              type="button"
              phx-click="close_todo_modal"
              class="dialog-close"
              aria-label="Close"
            >
              &times;
            </button>
          </header>

          <form
            id="new-todo-form"
            phx-change="change_todo"
            phx-submit="create_todo"
            class="dialog-form"
          >
            <label>
              Title
              <input
                type="text"
                name="title"
                value={@todo_form[:title].value}
                maxlength="80"
                autocomplete="off"
                required
              />
            </label>
            <label>
              Description <textarea
                name="message"
                rows="3"
                placeholder="Optional short note shown under the title."
              >{@todo_form[:message].value}</textarea>
              <small
                id="todo-message-count"
                class={message_length(@todo_form) > 200 && "is-over"}
              >
                {message_length(@todo_form)}/{200}
              </small>
            </label>
            <label>
              Link
              <input
                type="text"
                name="path"
                value={@todo_form[:path].value}
                placeholder="/settings or https://…"
                autocomplete="off"
              />
              <small>
                Optional. Without a link the todo has no button — it's just a reminder.
                Everyone on this site sees it in their checklist.
              </small>
            </label>
            <div class="dialog-footer">
              <button type="button" phx-click="close_todo_modal" class="btn">Cancel</button>
              <button
                type="submit"
                class="btn btn-primary"
                disabled={message_length(@todo_form) > 200}
              >
                Add todo
              </button>
            </div>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end
