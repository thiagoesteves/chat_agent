defmodule ChatAgentWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ChatAgentWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :max_width, :string,
    default: "max-w-2xl",
    doc: "class capping the content width, for pages that need more room"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar app-bar px-4 sm:px-6 lg:px-8">
      <a href="/" class="app-brand">
        <span class="app-brand-mark" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5Z"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <span class="app-brand-name">ChatBot</span>
      </a>

      <div class="app-bar-actions">
        <.user_menu current_scope={@current_scope} />
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @max_width]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Who is signed in, and what they can do about it.

  Sits in the app bar next to the theme toggle, so account actions and
  appearance live in the same place on every page. Signed out, it is the one
  link into the dashboard.

  ## Examples

      <.user_menu current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  def user_menu(assigns) do
    ~H"""
    <div class="app-user">
      <%= if @current_scope do %>
        <span class="app-user-name" title={@current_scope.user.email}>
          <.icon name="hero-user-circle-micro" />
          {@current_scope.user.email}
        </span>

        <.link href={~p"/users/settings"} class="app-user-link" title="Account settings">
          <.icon name="hero-cog-6-tooth-micro" />
          <span class="app-user-label">Settings</span>
        </.link>

        <.link href={~p"/users/log-out"} method="delete" class="app-user-link" title="Log out">
          <.icon name="hero-arrow-right-start-on-rectangle-micro" />
          <span class="app-user-label">Log out</span>
        </.link>
      <% else %>
        <.link href={~p"/users/log-in"} class="app-user-link" title="Log in">
          <.icon name="hero-arrow-right-end-on-rectangle-micro" />
          <span class="app-user-label">Log in</span>
        </.link>
      <% end %>
    </div>
    """
  end

  @doc """
  Three way theme selector: follow the system, or pin light or dark.

  The buttons only carry `data-set-theme`. `assets/js/theme.js` applies the
  choice to `<html data-theme>` before first paint and persists it, so the
  toggle works on any page and does not depend on a LiveView being connected.

  ## Examples

      <.theme_toggle />
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-toggle" role="group" aria-label="Colour theme">
      <span class="theme-toggle-indicator" aria-hidden="true"></span>

      <button type="button" data-set-theme="system" title="Follow system theme">
        <.icon name="hero-computer-desktop-micro" />
        <span class="sr-only">System theme</span>
      </button>

      <button type="button" data-set-theme="light" title="Light theme">
        <.icon name="hero-sun-micro" />
        <span class="sr-only">Light theme</span>
      </button>

      <button type="button" data-set-theme="dark" title="Dark theme">
        <.icon name="hero-moon-micro" />
        <span class="sr-only">Dark theme</span>
      </button>
    </div>
    """
  end
end
