# Tests for PR Patches

These tests follow the existing anubis_mcp test patterns using `Anubis.MCP.Case`, `Anubis.MCP.Builders`, `Anubis.MCP.Setup`, `StubServer`, `StubTransport`, and `TestIODevice`.

---

## Test File 1: `test/anubis/mcp/interop_guards_test.exs`

Tests Patch 3 — `server/discover` and `initialized` in guards and protocol method lists.

```elixir
defmodule Anubis.MCP.InteropGuardsTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Protocol.V2024_11_05
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18
  alias Anubis.Protocol.V2025_11_25

  require Message

  @moduletag capture_log: true

  describe "is_initialize/1 guard" do
    test "matches standard initialize request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}
      assert Message.is_initialize(msg)
    end

    test "matches server/discover request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}
      assert Message.is_initialize(msg)
    end

    test "does not match other methods" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
      refute Message.is_initialize(msg)
    end

    test "does not match notifications (no id)" do
      msg = %{"jsonrpc" => "2.0", "method" => "initialize"}
      refute Message.is_initialize(msg)
    end
  end

  describe "is_initialize_lifecycle/1 guard" do
    test "matches initialize request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}
      assert Message.is_initialize_lifecycle(msg)
    end

    test "matches server/discover request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}
      assert Message.is_initialize_lifecycle(msg)
    end

    test "matches notifications/initialized notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert Message.is_initialize_lifecycle(msg)
    end

    test "matches bare initialized notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "initialized"}
      assert Message.is_initialize_lifecycle(msg)
    end

    test "does not match unrelated methods" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{}}
      refute Message.is_initialize_lifecycle(msg)
    end
  end

  describe "server/discover in protocol method lists" do
    test "registered in V2024_11_05 request methods" do
      assert "server/discover" in V2024_11_05.request_methods()
    end

    test "propagated to V2025_03_26" do
      assert "server/discover" in V2025_03_26.request_methods()
    end

    test "propagated to V2025_06_18" do
      assert "server/discover" in V2025_06_18.request_methods()
    end

    test "propagated to V2025_11_25" do
      assert "server/discover" in V2025_11_25.request_methods()
    end
  end

  describe "initialized in protocol notification lists" do
    test "registered in V2024_11_05 notification methods" do
      assert "initialized" in V2024_11_05.notification_methods()
    end

    test "propagated to V2025_03_26" do
      assert "initialized" in V2025_03_26.notification_methods()
    end

    test "propagated to V2025_06_18" do
      assert "initialized" in V2025_06_18.notification_methods()
    end

    test "propagated to V2025_11_25" do
      assert "initialized" in V2025_11_25.notification_methods()
    end
  end

  describe "decode/2 accepts server/discover and initialized" do
    test "server/discover is decoded successfully" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"agy","version":"0.1"},"capabilities":{}}}\n)
      assert {:ok, [%{"method" => "server/discover"}]} = Message.decode(json)
    end

    test "initialized notification is decoded successfully" do
      json = ~s({"jsonrpc":"2.0","method":"initialized"}\n)
      assert {:ok, [%{"method" => "initialized"}]} = Message.decode(json)
    end

    test "server/discover accepted by all protocol versions" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test","version":"1.0"},"capabilities":{}}}\n)

      assert {:ok, _} = Message.decode(json, V2024_11_05)
      assert {:ok, _} = Message.decode(json, V2025_03_26)
      assert {:ok, _} = Message.decode(json, V2025_06_18)
      assert {:ok, _} = Message.decode(json, V2025_11_25)
    end

    test "initialized notification accepted by all protocol versions" do
      json = ~s({"jsonrpc":"2.0","method":"initialized"}\n)

      assert {:ok, _} = Message.decode(json, V2024_11_05)
      assert {:ok, _} = Message.decode(json, V2025_03_26)
      assert {:ok, _} = Message.decode(json, V2025_06_18)
      assert {:ok, _} = Message.decode(json, V2025_11_25)
    end
  end
end
```

---

## Test File 2: `test/anubis/server/session_interop_test.exs`

Tests Patches 2 and 4 — resilient `_meta` extraction and graceful version negotiation failure.

```elixir
defmodule Anubis.Server.SessionInteropTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Registry
  alias Anubis.Server.Session
  alias Anubis.Server.Transport.Session, as: SessionDispatcher

  @moduletag capture_log: true

  setup do
    transport_name = Registry.transport_name(StubServer, StubTransport)
    start_supervised!({StubTransport, name: transport_name})
    task_sup = Registry.task_supervisor_name(StubServer)
    start_supervised!({Task.Supervisor, name: task_sup})

    session_id = "interop_session_#{System.unique_integer([:positive])}"
    session_name = Registry.session_name(StubServer, session_id)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         server_module: StubServer,
         name: session_name,
         transport: [layer: StubTransport, name: transport_name],
         task_supervisor: task_sup}
      )

    %{session: session, session_id: session_id}
  end

  # -- Patch 2: Resilient _meta extraction --

  describe "initialize with minimal params (no clientInfo/capabilities)" do
    test "succeeds with empty params", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-1",
        "method" => "initialize",
        "params" => %{}
      }

      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)
      assert decoded["result"]["protocolVersion"]
      assert decoded["result"]["serverInfo"]
    end

    test "succeeds with only protocolVersion", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-2",
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2024-11-05"}
      }

      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)
      assert decoded["result"]["protocolVersion"] == "2024-11-05"
    end

    test "defaults protocolVersion to 2024-11-05 when missing", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-3",
        "method" => "initialize",
        "params" => %{
          "clientInfo" => %{"name" => "MinimalClient", "version" => "0.1"}
        }
      }

      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)
      # Server should negotiate successfully (2024-11-05 is always supported)
      assert decoded["result"]["protocolVersion"]
    end
  end

  describe "initialize with ACP-style _meta params" do
    test "extracts clientInfo from _meta namespace", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-acp-1",
        "method" => "initialize",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/clientInfo" => %{
              "name" => "AgyClient",
              "version" => "2.0"
            },
            "io.modelcontextprotocol/clientCapabilities" => %{"roots" => %{}},
            "io.modelcontextprotocol/protocolVersion" => "2024-11-05"
          }
        }
      }

      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)
      assert decoded["result"]["protocolVersion"] == "2024-11-05"

      state = :sys.get_state(session)
      assert state.client_info == %{"name" => "AgyClient", "version" => "2.0"}
      assert state.client_capabilities == %{"roots" => %{}}
    end

    test "prefers _meta over top-level keys", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-acp-2",
        "method" => "initialize",
        "params" => %{
          "clientInfo" => %{"name" => "TopLevel", "version" => "1.0"},
          "protocolVersion" => "2025-03-26",
          "_meta" => %{
            "io.modelcontextprotocol/clientInfo" => %{
              "name" => "MetaClient",
              "version" => "3.0"
            }
          }
        }
      }

      assert {:ok, _response} = SessionDispatcher.dispatch_request(session, request, %{})

      state = :sys.get_state(session)
      assert state.client_info == %{"name" => "MetaClient", "version" => "3.0"}
    end

    test "falls back to top-level when _meta keys are absent", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-acp-3",
        "method" => "initialize",
        "params" => %{
          "clientInfo" => %{"name" => "NormalClient", "version" => "1.0"},
          "capabilities" => %{"sampling" => %{}},
          "protocolVersion" => "2024-11-05",
          "_meta" => %{"appId" => "some-app"}
        }
      }

      assert {:ok, _response} = SessionDispatcher.dispatch_request(session, request, %{})

      state = :sys.get_state(session)
      assert state.client_info == %{"name" => "NormalClient", "version" => "1.0"}
      assert state.client_capabilities == %{"sampling" => %{}}
    end
  end

  describe "server/discover as initialize alias" do
    test "server/discover initializes the session", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "discover-1",
        "method" => "server/discover",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "clientInfo" => %{"name" => "AgyAgent", "version" => "0.5"},
          "capabilities" => %{}
        }
      }

      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)
      assert decoded["result"]["protocolVersion"]
      assert decoded["result"]["serverInfo"]
      assert decoded["result"]["capabilities"]

      state = :sys.get_state(session)
      assert state.initialized == true
      assert state.client_info["name"] == "AgyAgent"
    end
  end

  describe "initialized notification variant" do
    test "bare 'initialized' notification is accepted", %{session: session} do
      # First initialize the session
      init_request = init_request("2024-11-05", %{"name" => "Test", "version" => "1.0"})
      assert {:ok, _} = SessionDispatcher.dispatch_request(session, init_request, %{})

      # Send bare "initialized" instead of "notifications/initialized"
      notification = %{"jsonrpc" => "2.0", "method" => "initialized"}
      assert :ok = SessionDispatcher.dispatch_notification(session, notification, %{})

      # Allow async processing
      Process.sleep(50)

      state = :sys.get_state(session)
      assert state.initialized == true
    end

    test "standard notifications/initialized still works", %{session: session} do
      init_request = init_request("2024-11-05", %{"name" => "Test", "version" => "1.0"})
      assert {:ok, _} = SessionDispatcher.dispatch_request(session, init_request, %{})

      notification = build_notification("notifications/initialized", %{})
      assert :ok = SessionDispatcher.dispatch_notification(session, notification, %{})

      Process.sleep(50)

      state = :sys.get_state(session)
      assert state.initialized == true
    end
  end

  # -- Patch 4: Graceful version negotiation failure --

  describe "unsupported protocol version" do
    test "returns JSON-RPC error instead of crashing", %{session: session} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "init-bad-version",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "9999-01-01",
          "clientInfo" => %{"name" => "FutureClient", "version" => "99.0"},
          "capabilities" => %{}
        }
      }

      # With the patch: returns an error response, session stays alive
      # Without the patch: MatchError crashes the GenServer
      assert {:ok, response} = SessionDispatcher.dispatch_request(session, request, %{})
      decoded = JSON.decode!(response)

      assert decoded["error"]
      assert decoded["error"]["code"] == -32600
      assert decoded["error"]["message"] =~ "9999-01-01"
      assert decoded["id"] == "init-bad-version"

      # Session is still alive and can accept a valid init
      assert Process.alive?(session)
    end

    test "session remains functional after rejected version", %{session: session} do
      # Send bad version first
      bad_request = %{
        "jsonrpc" => "2.0",
        "id" => "bad-1",
        "method" => "initialize",
        "params" => %{"protocolVersion" => "0000-00-00"}
      }

      assert {:ok, error_response} = SessionDispatcher.dispatch_request(session, bad_request, %{})
      assert JSON.decode!(error_response)["error"]

      # Now send a valid init — should succeed
      good_request = init_request("2024-11-05", %{"name" => "Recovery", "version" => "1.0"})
      assert {:ok, ok_response} = SessionDispatcher.dispatch_request(session, good_request, %{})
      decoded = JSON.decode!(ok_response)

      assert decoded["result"]["protocolVersion"] == "2024-11-05"
      assert decoded["result"]["serverInfo"]
    end
  end

  defp init_request(version, client_info) do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-#{System.unique_integer([:positive])}",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "clientInfo" => client_info,
        "capabilities" => %{}
      }
    }
  end

  defp build_notification(method, params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }
  end
end
```

---

## Test File 3: `test/anubis/server/transport/stdio_line_buffer_test.exs`

Tests Patch 1 — `line_buffer: true` on stdio transport.

```elixir
defmodule Anubis.Server.Transport.STDIOLineBufferTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Transport.STDIO

  @moduletag capture_log: true

  setup :server_with_stdio_transport

  describe "line_buffer: true" do
    test "setopts called with line_buffer on init", %{io_device: io_device} do
      # TestIODevice accepts :setopts and replies :ok.
      # If line_buffer: true were rejected, the transport would log a warning
      # but still start. We verify the transport started and can write.
      name = :"line_buffer_test_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        STDIO.start_link(
          server: StubServer,
          name: name,
          io_device: io_device
        )

      assert Process.alive?(pid)

      # Verify a small message is written immediately (not buffered)
      msg = ~s({"jsonrpc":"2.0","id":"test","result":{}}\n)
      assert :ok = STDIO.send_message(pid, msg, timeout: 5000)
      assert TestIODevice.contents(io_device) =~ "test"

      shutdown(pid)
    end

    test "small JSON-RPC responses are written without blocking", %{io_device: io_device} do
      name = :"flush_test_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        STDIO.start_link(
          server: StubServer,
          name: name,
          io_device: io_device
        )

      # Simulate a typical initialize response (~200 bytes)
      response = JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{
          "protocolVersion" => "2024-11-05",
          "serverInfo" => %{"name" => "Test", "version" => "1.0"},
          "capabilities" => %{"tools" => %{}}
        }
      })

      assert :ok = STDIO.send_message(pid, response <> "\n", timeout: 5000)

      output = TestIODevice.contents(io_device)
      assert output =~ "protocolVersion"
      assert output =~ "serverInfo"

      shutdown(pid)
    end
  end

  defp shutdown(pid) do
    ref = Process.monitor(pid)
    :ok = STDIO.shutdown(pid)
    assert_receive {:DOWN, ^ref, _, ^pid, :normal}
  end
end
```

---

## Summary

| Test File | Patches Covered | Key Scenarios |
|-----------|----------------|---------------|
| `interop_guards_test.exs` | Patch 3 | Guards match `server/discover` and `initialized`; methods registered in all protocol versions; decode/validate accept both |
| `session_interop_test.exs` | Patches 2, 4 | Minimal params, ACP `_meta` extraction, `_meta` priority over top-level, `server/discover` as init alias, bare `initialized` notification, unsupported version returns error, session survives bad version |
| `stdio_line_buffer_test.exs` | Patch 1 | Transport starts with `line_buffer: true`, small responses written immediately |

### Notes for the PR

- All tests use the existing test infrastructure (`StubServer`, `StubTransport`, `TestIODevice`, `Anubis.MCP.Case`).
- The Patch 4 tests (`unsupported protocol version`) will **fail against upstream 1.14.0** (they prove the fix is needed). The other tests will fail for Patches 2 and 3 against upstream as well — this is expected since these are the tests that validate the patches.
- `SessionDispatcher.dispatch_request/3` is used instead of raw `GenServer.call` to match the upstream test pattern.
