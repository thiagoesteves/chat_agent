defmodule ChatAgentWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use ChatAgentWeb, :html

  embed_templates "page_html/*"

  # The landing page copy lives here rather than inline in the template, so the
  # markup stays one loop per section and the wording is edited in one place.

  defp steps do
    [
      %{
        title: "A message arrives",
        body: "WhatsApp or Telegram posts to this app's webhook and the request is authenticated."
      },
      %{
        title: "It is normalised",
        body: "Each channel unwraps its own envelope into one message struct, whatever the shape."
      },
      %{
        title: "An agent answers",
        body:
          "A conversation activated with a password is routed to a local agent, such as Claude."
      },
      %{
        title: "The reply goes back",
        body:
          "Out on the channel the message came in on, and onto the dashboard at the same time."
      }
    ]
  end

  defp features do
    [
      %{
        icon: "hero-inbox-stack-micro",
        title: "One inbox, many channels",
        body: """
        WhatsApp Cloud API and Telegram Bot API today, and a channel is one module implementing a
        behaviour plus a route. Nothing else has to change to add the next one.
        """
      },
      %{
        icon: "hero-cpu-chip-micro",
        title: "Agents you already run",
        body: """
        An agent adapter drives a CLI on your own machine, so the conversation never leaves it.
        Each conversation keeps its own history.
        """
      },
      %{
        icon: "hero-signal-micro",
        title: "Live dashboard",
        body: """
        Messages appear as they arrive over PubSub, with the identifiers each service reported and
        a composer to reply from.
        """
      },
      %{
        icon: "hero-globe-alt-micro",
        title: "Reachable from anywhere",
        body: """
        A deployment behind DNS uses its own host. On a laptop, a tunnel opens a public URL and
        registers it with every channel that accepts one.
        """
      }
    ]
  end

  defp routes do
    [
      %{path: "/", public: true, purpose: "This page."},
      %{path: "/channels", public: false, purpose: "The live dashboard."},
      %{path: "/whatsapp/webhook", public: true, purpose: "WhatsApp handshake and messages."},
      %{
        path: "/telegram/webhook",
        public: true,
        purpose: "Telegram updates, guarded by a secret."
      },
      %{path: "/health", public: true, purpose: "Liveness probe."}
    ]
  end
end
