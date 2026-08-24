defmodule ChatAgent.Channel.TelegramTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias ChatAgent.Channel.Health
  alias ChatAgent.Channel.Message
  alias ChatAgent.Channel.Telegram

  setup do
    configured = Application.get_env(:chat_agent, Telegram)

    download_dir =
      Path.join(System.tmp_dir!(), "telegram_test_#{System.unique_integer([:positive])}")

    Application.put_env(
      :chat_agent,
      Telegram,
      Keyword.put(configured, :download_dir, download_dir)
    )

    on_exit(fn ->
      Application.put_env(:chat_agent, Telegram, configured)
      File.rm_rf!(download_dir)
    end)

    %{download_dir: download_dir}
  end

  describe "handle_message/1" do
    test "processes a text message" do
      # A private chat, where Telegram reports the same number for both: the
      # chat id of a one to one conversation is the user's own id.
      update = %{
        "update_id" => 1,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "from" => %{"id" => 123_456},
          "text" => "Hello"
        }
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.id == "1"
      assert parsed.sender == "123456"
      assert parsed.conversation == "123456"

      assert parsed.identifiers == [
               {"chat.id", "123456"},
               {"from.id", "123456"},
               {"update_id", "1"}
             ]

      assert parsed.text == "Hello"
      assert %DateTime{} = parsed.received_at
    end

    test "answers a message it has nothing to show, rather than looping on it" do
      # The clause that handles a chat message matches any message with a chat
      # id, so falling back by calling this function again matched it again,
      # and the webhook process spun forever.
      for content <- [
            %{"sticker" => %{"file_id" => "x"}},
            %{"location" => %{"latitude" => 1, "longitude" => 2}},
            %{"new_chat_members" => []},
            %{"poll" => %{"question" => "?"}}
          ] do
        update = %{"update_id" => 9, "message" => Map.put(content, "chat", %{"id" => 123_456})}

        task = Task.async(fn -> Telegram.handle_message(update) end)

        assert {:ok, :ok} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
      end
    end

    test "answers a payload shaped like nothing it knows, rather than raising" do
      # A webhook that raises answers 500, and the sender retries for as long
      # as it cares to. Anything can arrive here when no secret is configured.
      for content <- [
            %{"photo" => "not-a-list"},
            %{"document" => "not-a-map"},
            %{"photo" => []},
            %{"audio" => nil}
          ] do
        update = %{"update_id" => 8, "message" => Map.put(content, "chat", %{"id" => 123_456})}

        assert :ok = Telegram.handle_message(update)
      end
    end

    test "fetches nothing for a conversation nobody listed", %{download_dir: download_dir} do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)

      Application.put_env(
        :chat_agent,
        Telegram,
        Keyword.put(configured, :allowed_chat_ids, ["123456"])
      )

      update = %{
        "update_id" => 11,
        "message" => %{
          "chat" => %{"id" => 999_999},
          "document" => %{"file_id" => "file-1", "file_name" => "invoice.pdf"}
        }
      }

      # Nothing is stubbed, so any request would raise rather than quietly
      # succeed: a stranger cannot make this fetch and keep a file that the
      # routing facade is about to drop anyway.
      assert :ok = Telegram.handle_message(update)
      refute File.exists?(download_dir)
    end

    test "keeps a caption from a conversation nobody listed, without the file" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)

      Application.put_env(
        :chat_agent,
        Telegram,
        Keyword.put(configured, :allowed_chat_ids, ["123456"])
      )

      update = %{
        "update_id" => 12,
        "message" => %{
          "chat" => %{"id" => 999_999},
          "caption" => "look at this",
          "document" => %{"file_id" => "file-1", "file_name" => "invoice.pdf"}
        }
      }

      # The facade drops it a moment later, and what it drops says what was
      # said rather than nothing at all.
      assert {:ok, %Message{text: "look at this"}} = Telegram.handle_message(update)
    end

    test "says a file could not be downloaded, rather than losing the message" do
      for {stub, expected} <- [
            {fn conn ->
               Req.Test.json(conn, %{"ok" => false, "description" => "file is too big"})
             end, "could not be downloaded"},
            {fn conn -> Plug.Conn.send_resp(conn, 502, "Bad Gateway") end,
             "could not be downloaded"},
            {fn conn -> Req.Test.transport_error(conn, :econnrefused) end,
             "could not be downloaded"}
          ] do
        Req.Test.stub(Telegram, stub)

        update = %{
          "update_id" => 14,
          "message" => %{
            "chat" => %{"id" => 123_456},
            "caption" => "the invoice",
            "document" => %{"file_id" => "file-1", "file_name" => "invoice.pdf"}
          }
        }

        # What somebody said arrives either way: a download that failed is
        # worth saying, and worth saying beside what it was sent with.
        assert {:ok, %Message{text: text}} = Telegram.handle_message(update)
        assert text =~ "the invoice"
        assert text =~ expected
      end
    end

    test "reports a download the network refused" do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getFile" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"file_path" => "documents/a.pdf"}})

          _file ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      update = %{
        "update_id" => 16,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "document" => %{"file_id" => "file-1", "file_name" => "a.pdf"}
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)
      assert text =~ "could not be downloaded"
    end

    test "reports a file the download itself refused", %{download_dir: download_dir} do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getFile" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"file_path" => "documents/a.pdf"}})

          _file ->
            Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      update = %{
        "update_id" => 15,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "document" => %{"file_id" => "file-1", "file_name" => "a.pdf"}
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)
      assert text =~ "could not be downloaded"
      refute File.exists?(Path.join(download_dir, "a.pdf"))
    end

    test "keeps a file whatever its content type says it is", %{download_dir: download_dir} do
      body = ~s({"invoice": 1})

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getFile" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"file_path" => "documents/report.json"}
            })

          _file ->
            # Req decodes by content type, so without asking for the bytes a
            # JSON attachment arrives as a map and a finished download reads
            # as a failure.
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, body)
        end
      end)

      update = %{
        "update_id" => 13,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "document" => %{
            "file_id" => "file-json",
            "file_name" => "report.json",
            "mime_type" => "application/json",
            "file_size" => 999
          }
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)
      assert text =~ "Telegram attachment downloaded."
      refute text =~ "could not be downloaded"

      [path] = Path.wildcard(Path.join(download_dir, "*report.json"))
      assert File.read!(path) == body
      # The size is what reached the disk, not what the payload claimed.
      assert text =~ "Size: #{byte_size(body)} bytes"
      refute text =~ "999"
    end

    test "downloads a document and gives the assistant its local path", %{
      download_dir: download_dir
    } do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getFile" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "result" => %{"file_path" => "documents/report.xlsx"}
            })

          "/file/bottest_telegram_bot_token/documents/report.xlsx" ->
            Plug.Conn.send_resp(conn, 200, "spreadsheet contents")
        end
      end)

      update = %{
        "update_id" => 4,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "from" => %{"id" => 123_456},
          "caption" => "Please inspect this spreadsheet",
          "document" => %{
            "file_id" => "document-file-id",
            "file_name" => "../../report.xlsx",
            "mime_type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "file_size" => 19
          }
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)
      assert text =~ "Please inspect this spreadsheet"

      assert text =~
               "MIME type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      assert [path] = Path.wildcard(Path.join(download_dir, "4-*"))
      assert text =~ "Local path: #{path}"

      digest =
        :crypto.hash(:sha256, "document-file-id")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)

      assert Path.basename(path) == "4-#{digest}-report.xlsx"
      assert File.read!(path) == "spreadsheet contents"
    end

    test "downloads the largest photo when a message has several sizes", %{
      download_dir: download_dir
    } do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getFile" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"file_path" => "photos/image.jpg"}})

          "/file/bottest_telegram_bot_token/photos/image.jpg" ->
            Plug.Conn.send_resp(conn, 200, <<255, 216, 255, 217>>)
        end
      end)

      update = %{
        "update_id" => 5,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "photo" => [
            %{"file_id" => "small-photo", "width" => 100, "height" => 100},
            %{"file_id" => "large-photo", "width" => 1000, "height" => 1000}
          ]
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)

      digest =
        :crypto.hash(:sha256, "large-photo") |> Base.encode16(case: :lower) |> String.slice(0, 12)

      path = Path.join(download_dir, "5-#{digest}-image.jpg")
      assert text =~ "Local path: #{path}"
      assert File.read!(path) == <<255, 216, 255, 217>>
    end

    test "keeps a message when Telegram cannot download its attachment" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "file is unavailable"})
      end)

      update = %{
        "update_id" => 6,
        "message" => %{
          "chat" => %{"id" => 123_456},
          "caption" => "The file is missing",
          "document" => %{"file_id" => "missing-file", "file_name" => "missing.csv"}
        }
      }

      assert {:ok, %Message{text: text}} = Telegram.handle_message(update)

      assert text ==
               Enum.join(
                 ["The file is missing", "Telegram attachment could not be downloaded."],
                 "\n\n"
               )
    end

    test "separates the person from the conversation in a group" do
      update = %{
        "update_id" => 2,
        "message" => %{
          "chat" => %{"id" => -1_001_234_567_890},
          "from" => %{"id" => 42},
          "text" => "Hello"
        }
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.sender == "42"
      assert parsed.conversation == "-1001234567890"

      assert parsed.identifiers == [
               {"chat.id", "-1001234567890"},
               {"from.id", "42"},
               {"update_id", "2"}
             ]
    end

    test "falls back to the chat when the payload names no sender" do
      update = %{
        "update_id" => 3,
        "message" => %{"chat" => %{"id" => 99}, "text" => "Hello"}
      }

      assert {:ok, %Message{} = parsed} = Telegram.handle_message(update)
      assert parsed.sender == "99"
      assert parsed.conversation == "99"

      # No from.id arrived, so none is reported rather than echoing the chat id
      # back under a name the payload never used.
      assert parsed.identifiers == [{"chat.id", "99"}, {"update_id", "3"}]
    end

    test "processes an unknown update" do
      assert :ok = Telegram.handle_message(%{"update_id" => 1})
    end
  end

  describe "send_message/2" do
    test "posts a text message to the Bot API" do
      Req.Test.stub(Telegram, fn conn ->
        assert conn.method == "POST"
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      assert :ok = Telegram.send_message(123_456, "Hello")
    end

    test "reports a failure the Bot API answers 200 with" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "chat not found"})
      end)

      assert {:error, {:telegram_error, "chat not found"}} = Telegram.send_message(0, "Hello")
    end

    test "reports an unexpected status" do
      Req.Test.stub(Telegram, fn conn ->
        Plug.Conn.send_resp(conn, 502, "Bad Gateway")
      end)

      assert {:error, {:http_error, 502}} = Telegram.send_message(123_456, "Hello")
    end

    test "reports a transport error" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Telegram.send_message(123_456, "Hello")
    end
  end

  describe "register_webhook/2" do
    test "sets the webhook, with the configured secret, when it points elsewhere" do
      test_process = self()

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => "https://old.example.com"}})

          "/bottest_telegram_bot_token/setWebhook" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_process, {:set_webhook, Jason.decode!(body)})
            Req.Test.json(conn, %{"ok" => true, "result" => true})
        end
      end)

      assert {:ok, :registered} =
               Telegram.register_webhook("https://a1b2c3.ngrok-free.app/telegram/webhook", [])

      assert_receive {:set_webhook, payload}
      assert payload["url"] == "https://a1b2c3.ngrok-free.app/telegram/webhook"
      assert payload["secret_token"] == "test_telegram_webhook_secret"
    end

    test "sets no secret token when none is configured" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :webhook_secret))

      test_process = self()

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{}})

          "/bottest_telegram_bot_token/setWebhook" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_process, {:set_webhook, Jason.decode!(body)})
            Req.Test.json(conn, %{"ok" => true, "result" => true})
        end
      end)

      assert {:ok, :registered} =
               Telegram.register_webhook("https://example.com/telegram/webhook", [])

      assert_receive {:set_webhook, payload}
      refute Map.has_key?(payload, "secret_token")
    end

    test "leaves a webhook that already points there alone" do
      Req.Test.stub(Telegram, fn conn ->
        assert conn.request_path == "/bottest_telegram_bot_token/getWebhookInfo"

        Req.Test.json(conn, %{
          "ok" => true,
          "result" => %{"url" => "https://a1b2c3.ngrok-free.app/telegram/webhook"}
        })
      end)

      assert {:ok, :unchanged} =
               Telegram.register_webhook("https://a1b2c3.ngrok-free.app/telegram/webhook", [])
    end

    test "reports a failure reading what is registered" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "Unauthorized"})
      end)

      assert {:error, {:telegram_error, "Unauthorized"}} =
               Telegram.register_webhook("https://example.com/telegram/webhook", [])
    end

    test "reports a failure setting the webhook" do
      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => ""}})

          "/bottest_telegram_bot_token/setWebhook" ->
            Req.Test.json(conn, %{"ok" => false, "description" => "bad webhook: HTTPS required"})
        end
      end)

      assert {:error, {:telegram_error, "bad webhook: HTTPS required"}} =
               Telegram.register_webhook("http://example.com/telegram/webhook", [])
    end

    test "reports a transport error" do
      Req.Test.stub(Telegram, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Telegram.register_webhook("https://example.com/telegram/webhook", [])
    end

    test "reports an answer it does not recognise" do
      Req.Test.stub(Telegram, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:error, :unexpected_response} =
               Telegram.register_webhook("https://example.com/telegram/webhook", [])
    end
  end

  describe "register_webhook/2, forced" do
    test "writes the registration without reading back where it points" do
      test_process = self()

      Req.Test.stub(Telegram, fn conn ->
        case conn.request_path do
          "/bottest_telegram_bot_token/getWebhookInfo" ->
            flunk("read the registration back on a forced write")

          "/bottest_telegram_bot_token/setWebhook" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_process, {:set_webhook, Jason.decode!(body)})
            Req.Test.json(conn, %{"ok" => true, "result" => true})
        end
      end)

      # The URL the Bot API already has. Writing it again is the whole point:
      # that is what makes it resolve the host afresh.
      assert {:ok, :registered} =
               Telegram.register_webhook("https://a1b2c3.ngrok-free.app/telegram/webhook",
                 force: true
               )

      assert_receive {:set_webhook, payload}
      assert payload["url"] == "https://a1b2c3.ngrok-free.app/telegram/webhook"
    end
  end

  describe "webhook_health/0" do
    test "reports a service that is delivering" do
      stub_webhook_info(%{
        "url" => "https://a1b2c3.ngrok-free.app/telegram/webhook",
        "pending_update_count" => 0,
        "ip_address" => "3.125.223.134"
      })

      assert {:ok, %Health{} = health} = Telegram.webhook_health()
      assert health.state == :ok
      assert health.url == "https://a1b2c3.ngrok-free.app/telegram/webhook"
      assert health.pending == 0
      assert health.last_error == nil
      assert health.details == %{"ip_address" => "3.125.223.134"}
      assert %DateTime{} = health.checked_at
    end

    test "reports a queue held behind a failure that has just happened" do
      failed_at = DateTime.utc_now() |> DateTime.add(-26, :second) |> DateTime.to_unix()

      stub_webhook_info(%{
        "url" => "https://a1b2c3.ngrok-free.app/telegram/webhook",
        "pending_update_count" => 3,
        "last_error_date" => failed_at,
        "last_error_message" => "Connection timed out"
      })

      assert {:ok, %Health{} = health} = Telegram.webhook_health()
      assert health.state == :failing
      assert health.pending == 3
      assert health.last_error == "Connection timed out"
      assert DateTime.to_unix(health.last_error_at) == failed_at
    end

    # The Bot API reports the last failure there ever was, not a current one,
    # and goes on reporting it long after the delivery that followed it worked.
    test "does not read a failure the service has since recovered from as one" do
      stub_webhook_info(%{
        "url" => "https://a1b2c3.ngrok-free.app/telegram/webhook",
        "pending_update_count" => 0,
        "last_error_date" => DateTime.utc_now() |> DateTime.to_unix(),
        "last_error_message" => "Connection timed out"
      })

      assert {:ok, %Health{state: :ok, last_error: "Connection timed out"}} =
               Telegram.webhook_health()
    end

    test "does not read an old failure as one that is happening now" do
      failed_at = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_unix()

      stub_webhook_info(%{
        "url" => "https://a1b2c3.ngrok-free.app/telegram/webhook",
        "pending_update_count" => 5,
        "last_error_date" => failed_at,
        "last_error_message" => "Wrong response from the webhook: 502 Bad Gateway"
      })

      assert {:ok, %Health{state: :ok, pending: 5}} = Telegram.webhook_health()
    end

    test "reports a queue with no failure behind it as delivery in progress" do
      # Updates arriving faster than they are handed over, which is a busy
      # webhook rather than a broken one: nothing has failed at all.
      stub_webhook_info(%{
        "url" => "https://a1b2c3.ngrok-free.app/telegram/webhook",
        "pending_update_count" => 4
      })

      assert {:ok, %Health{state: :ok, pending: 4, last_error_at: nil}} =
               Telegram.webhook_health()
    end

    test "reports no URL at all, rather than an empty one" do
      stub_webhook_info(%{"url" => "", "pending_update_count" => 0})

      assert {:ok, %Health{url: nil}} = Telegram.webhook_health()
    end

    test "reports a check that could not be made" do
      Req.Test.stub(Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "Unauthorized"})
      end)

      assert {:error, {:telegram_error, "Unauthorized"}} = Telegram.webhook_health()
    end
  end

  describe "authenticate/1" do
    test "accepts a request carrying the configured secret" do
      request = conn(:post, "/telegram/webhook", "")

      request =
        Plug.Conn.put_req_header(
          request,
          "x-telegram-bot-api-secret-token",
          "test_telegram_webhook_secret"
        )

      assert :ok = Telegram.authenticate(request)
    end

    test "rejects a request with the wrong secret" do
      request = conn(:post, "/telegram/webhook", "")
      request = Plug.Conn.put_req_header(request, "x-telegram-bot-api-secret-token", "wrong")

      assert {:error, :forbidden} = Telegram.authenticate(request)
    end

    test "rejects a request with no secret header at all" do
      assert {:error, :forbidden} = Telegram.authenticate(conn(:post, "/telegram/webhook", ""))
    end

    test "accepts any request when no secret is configured" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :webhook_secret))

      assert :ok = Telegram.authenticate(conn(:post, "/telegram/webhook", ""))
    end
  end

  describe "configuration" do
    test "says what is missing, and where to set it, when the token is not configured" do
      configured = Application.get_env(:chat_agent, Telegram)
      on_exit(fn -> Application.put_env(:chat_agent, Telegram, configured) end)
      Application.put_env(:chat_agent, Telegram, Keyword.delete(configured, :bot_token))

      assert_raise RuntimeError, ~r/no bot_token configured for ChatAgent.Channel.Telegram/, fn ->
        Telegram.send_message(123_456, "Hello")
      end
    end
  end

  describe "reference/0" do
    test "names the identifiers and where they are documented" do
      reference = Telegram.reference()

      assert reference.url =~ "core.telegram.org"
      assert {"chat.id", _} = Enum.find(reference.fields, &match?({"chat.id", _}, &1))
      assert {"from.id", _} = Enum.find(reference.fields, &match?({"from.id", _}, &1))
      assert {"update_id", _} = Enum.find(reference.fields, &match?({"update_id", _}, &1))
    end
  end

  describe "verify_subscription/1" do
    test "reports that the Bot API performs no handshake" do
      assert {:error, :not_found} = Telegram.verify_subscription(%{})
    end
  end

  describe "inbound_messages/1" do
    test "returns the update as the only payload" do
      update = %{"update_id" => 1, "message" => %{"text" => "Hello"}}

      assert {:ok, [^update]} = Telegram.inbound_messages(update)
    end

    test "rejects a body that is not an update" do
      assert {:error, :bad_request} = Telegram.inbound_messages(%{})
    end
  end

  ### ==========================================================================
  ### Helpers
  ### ==========================================================================

  defp stub_webhook_info(result) do
    Req.Test.stub(Telegram, fn conn ->
      assert conn.request_path == "/bottest_telegram_bot_token/getWebhookInfo"

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)
  end
end
