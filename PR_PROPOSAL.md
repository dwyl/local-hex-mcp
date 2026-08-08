# PR Proposal: stdio should reply to requests it cannot decode

## Problem

`Anubis.MCP.Message.decode/1` returns `{:error, :method_not_found}` for a request
whose method is not in `protocol_module.request_methods()`. The two server
transports then diverge:

| Transport | On `{:error, :method_not_found}` |
| :--- | :--- |
| `StreamableHTTP.Plug` | replies `-32601`, id recovered from the body |
| `STDIO` | logs `parse_error` and returns — **nothing is written** |

A request carrying an `id` therefore gets no response over stdio. That is a
JSON-RPC violation on its own, and from the client's side it is
indistinguishable from a server that has hung.

## Why it shows up now

anubis 2.x supports 2025-03-26 through 2025-11-25. The **2026-07-28** spec
retires the `initialize` handshake and has clients probe a new `server/discover`
method first, **falling back to `initialize` against older servers**.

That fallback is the correct interop story and it needs no changes here — but it
never fires, because the probe gets silence instead of an error. A client that
asks a question this server cannot answer is left waiting rather than told
"unknown method".

Note this affects only clients that *ask*. Claude Code sends `initialize`
directly and never touches the path, which is why the bug has stayed invisible.

## Reproduction

Google Antigravity CLI (`antigravity-client v1.0.0`, announcing `2026-07-28`),
stdio, anubis 2.0.0. Three consecutive attempts, identical:

```
09:26:12.440  incoming (325 B)  server/discover
09:26:12.445  parse_error :method_not_found        ← nothing written
09:26:17.949  SIGTERM received - shutting down     ← client gave up, 5s later
```

`initialize` is never sent. The client is waiting for a reply to request id 1.

With the patch below, same client, same probe:

```
11:24:46.440   incoming (325 B)  server/discover
11:24:46.445   parse_error :method_not_found       ← -32601 written
11:24:46.4467  incoming (232 B)  initialize        ← fallback, 1.7 ms later
11:24:46.4477  initializing, protocol 2025-11-25
11:24:46.4479  notifications/initialized
11:24:46.4481  tools/list (id 3)
```

Session up, tools listed and callable. The client downgrades itself unaided: it
advertises `2026-07-28` in `params._meta` on the probe, then requests
`2025-11-25` outright in the fallback. The server needs to know nothing about
2026-07-28 for this to work — only to say no.

## Patch

`lib/anubis/server/transport/stdio.ex`, plus `alias Anubis.MCP.Error`:

```diff
       {:error, reason} ->
         Logging.transport_event("parse_error", %{reason: reason}, level: :error)
+        reply_error(data, reason, state)
     end
   end
 
+  # `Message.decode/1` rejects a request whose method the negotiated protocol
+  # version does not define, but stdio only logged it. A client probing for a
+  # method this server does not implement was left waiting on a request id that
+  # was never going to be answered. `StreamableHTTP.Plug` already replies here.
+  # Notifications carry no id and must stay unanswered.
+  defp reply_error(data, reason, state) when reason in [:method_not_found, :invalid_request] do
+    with {:ok, %{"id" => id} = message} when not is_nil(id) <- JSON.decode(data),
+         error = Error.protocol(reason, Map.take(message, ["method"])),
+         {:ok, encoded} <- Error.to_json_rpc(error, id) do
+      IO.write(state.io_device, encoded)
+    else
+      _ -> :ok
+    end
+  end
+
+  defp reply_error(_data, _reason, _state), do: :ok
+
   defp process_message(message, %{server: server_module} = state) do
```

### Notes

- **One message per call.** `read_from_stdin/1` uses `IO.read(device, :line)`, so
  `handle_incoming_data/2` always receives exactly one message. No splitting.
- **`reason` comes from `decode/1`**, so there is no need to re-validate.
- **Notifications stay silent.** No `id`, no reply — answering one would itself
  violate JSON-RPC, and unknown notifications are routine.
- **Malformed JSON stays silent.** No id is recoverable, so there is nothing to
  answer. `StreamableHTTP.Plug` substitutes `ID.generate_error_id()` for a
  missing id, inventing an id no client asked about; that is deliberately not
  copied here, and may be worth revisiting on the HTTP side.
- **`Message.encode_error/2` already appends the trailing newline**, so the
  encoded string is written as-is.
- The existing `parse_error` log line is untouched.

### Verification

- Compiles clean against 2.0.0.
- Unknown method with an id → `{"error":{"code":-32601,"data":{"method":"server/discover"},"message":"Method not found"},"id":1,"jsonrpc":"2.0"}`
- Unknown notification → zero bytes written.
- Malformed JSON → zero bytes written.
- Clients that only send known methods never reach the branch; verified
  unchanged against Claude Code on the same build.

## Tests

`test/anubis/server/transport/stdio_test.exs`, driving the transport with
`StringIO` as `:io_device`:

- unknown method **with** an id → one `-32601`, `id` preserved, `data.method` set
- unknown **notification** → nothing written
- malformed JSON → nothing written, `parse_error` still logged
- known method → unchanged, nothing extra written

## Deliberately not in this PR

- **`server/discover` support.** Adding it to `request_methods/0` and letting the
  initialize handler answer it does make 2026-spec clients connect, but it makes
  a discovery probe establish a session (`initialized: true` without a
  handshake) and claims a spec version the server does not implement. It also
  turns out to be unnecessary: the client's own fallback works once it gets an
  answer. `server/discover` belongs in a `V2026_07_28` module alongside the
  `:stateless` era `Anubis.Protocol.Behaviour` already anticipates.
- **Resilient params extraction in `Session.handle_request/4`.** The strict
  destructure of `clientInfo` / `capabilities` / `protocolVersion` raises
  `MatchError` and kills the session without a reply — the same "client hangs
  because nobody answered" failure, reached another way. Worth fixing, separate
  PR.
