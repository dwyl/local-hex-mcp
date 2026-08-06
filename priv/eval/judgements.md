# Relevance judgements

Mark each result: `y` relevant, `n` not, `?` undecided. Only the leading
character matters; everything after the tab-separated package and URL is
there for you to read.

A judgement is keyed on package + URL, so it survives re-chunking and
re-indexing. Regenerate with `mix docs.judge` — existing marks are kept.

Score against these with `mix docs.eval --judged`.

## how do I automatically retry a failed request with backoff
<!-- concept -->

? req	https://req.hexdocs.pm/0.7.2/changelog.html#step-changes
  Step changes - CHANGELOG - Part 2
  * [`retry`]: The `:retry` option can now be set to `:safe` (default) to only retry GET/HEAD requests on HTTP 408/429/5xx responses or exceptions, `:al

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#expect/3-examples
  Examples - Req.Test.expect/3
  Let's simulate a server that is having issues: on the first request it is not responding and on the following two requests it returns an HTTP 500. Onl

? req	https://req.hexdocs.pm/0.7.2/Req.Steps.html#retry/1-request-options
  Request Options - Req.Steps.retry/1 - Part 1
  * `:retry` - can be one of the following: * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of: * HTTP 408/429/500/502/503/504 res

? req	https://req.hexdocs.pm/0.7.2/Req.html#new/2-options
  Options - Req.new/2 - Part 8
  * `:retry` - can be one of the following: * `:safe_transient` (default) - retry safe (GET/HEAD) requests on one of: * HTTP 408/429/500/502/503/504 res

? req	https://req.hexdocs.pm/0.7.2/changelog.html#full-changelog
  Full CHANGELOG - CHANGELOG - Part 3
  * [`retry`]: Support `retry: &fun/2`. The function receives `request, response_or_exception` and returns either: * `true` - retry with the default del

? req	https://req.hexdocs.pm/0.7.2/changelog.html#testing-enhancements
  Testing Enhancements - CHANGELOG - Part 2
  The important part is the request expectations are meant to run in order (and fail if they don't). In this release we're also adding [`Req.Test.transp

? req	https://req.hexdocs.pm/0.7.2/Req.Steps.html#retry/1-examples
  Examples - Req.Steps.retry/1
  iex> Req.get!("https://httpbin.org/status/500,200").status # 08:43:19.101 [warning] retry: got response with status 500, will retry in 941ms, 2 attemp


## replace real HTTP calls in my tests with a stub
<!-- concept -->

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#stub/2
  Req.Test.stub/2
  Creates a request stub with the given `name` and `plug`. Req allows running requests against _plugs_ (instead of over the network) using the [`:plug`]

? req	https://req.hexdocs.pm/0.7.2/changelog.html#testing-enhancements
  Testing Enhancements - CHANGELOG - Part 1
  In previous releases, we could only create test _stubs_ (using [`Req.Test.stub/2`]), that is, fake HTTP servers which had predefined behaviour. Let's 

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html
  Req.Test
  Req testing conveniences. Req is composed of: * `Req` - the high-level API * `Req.Request` - the low-level API and the request struct * `Req.Steps` - 

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#module-concurrency-and-allowances
  Concurrency and Allowances - Req.Test
  The example above works in concurrent tests because `MyApp.Weather.get_rating/1` calls directly to `Req.request/1` *in the same process*. It also work

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#module-example
  Example - Req.Test
  Imagine we're building an app that displays weather for a given location using an HTTP weather service: defmodule MyApp.Weather do def get_rating(loca

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#module-broadway
  Broadway - Req.Test
  If you're using `Req.Test` with [Broadway](https://hex.pm/packages/broadway), you may need to use `allow/3` to make stubs available in the Broadway pr

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#expect/3-examples
  Examples - Req.Test.expect/3
  Let's simulate a server that is having issues: on the first request it is not responding and on the following two requests it returns an HTTP 500. Onl

? req	https://req.hexdocs.pm/0.7.2/Req.Test.html#stub/2-examples
  Examples - Req.Test.stub/2
  iex> Req.Test.stub(MyStub, fn conn -> ...> send(self(), :req_happened) ...> Req.Test.json(conn, %{}) ...> end) :ok iex> Req.get!(plug: {Req.Test, MySt


## follow redirects returned by the server
<!-- concept -->

? req	https://req.hexdocs.pm/0.7.2/Req.TooManyRedirectsError.html
  Req.TooManyRedirectsError
  Represents an error when too many redirects occurred, returned by `Req.Steps.redirect/1`.

? req	https://req.hexdocs.pm/0.7.2/Req.Steps.html#redirect/1
  Req.Steps.redirect/1
  Follows redirects. The original request method may be changed to GET depending on the status code: | Code | Method handling | | ------------- | ------

? req	https://req.hexdocs.pm/0.7.2/Req.Steps.html#redirect/1-request-options
  Request Options - Req.Steps.redirect/1
  * `:redirect` - if set to `false`, disables automatic response redirects. Defaults to `true`. * `:redirect_trusted` - by default, authorization creden

? req	https://req.hexdocs.pm/0.7.2/changelog.html#full-changelog
  Full CHANGELOG - CHANGELOG - Part 2
  * Deprecate `output` step in favour of `into: File.stream!(path)`. * Rename `follow_redirects` step to [`redirect`] * [`redirect`]: Rename `:follow_re

? req	https://req.hexdocs.pm/0.7.2/Req.html#new/2-options
  Options - Req.new/2 - Part 7
  Response redirect options ([`redirect`](`Req.Steps.redirect/1`) step): * `:redirect` - if set to `false`, disables automatic response redirects. Defau

? req	https://req.hexdocs.pm/0.7.2/changelog.html#v0-3-3-2022-12-08
  v0.3.3 (2022-12-08) - CHANGELOG
  * [`follow_redirects`]: Inherit scheme from previous location * [`run_finch`]: Fix setting connect timeout * [`run_finch`]: Add `:finch_request` optio

? req	https://req.hexdocs.pm/0.7.2/changelog.html#v0-4-14-2024-03-15
  v0.4.14 (2024-03-15) - CHANGELOG
  * [`redirect`]: Return [`Req.TooManyRedirectsError`] exception. Previously we _always_ raised a `RuntimeError`. Besides changing the exception struct,

? req	https://req.hexdocs.pm/0.7.2/changelog.html#v0-3-7-2023-05-18
  v0.3.7 (2023-05-18) - CHANGELOG
  * Deprecate setting headers to `%NaiveDateTime{}`, always use `%DateTime{}`. * [`decode_body`]: Add `:decode_json` option * [`follow_redirects`]: Add 


## turn on write ahead logging so readers do not block writers
<!-- concept -->

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Connection.html#module-unknowns
  Unknowns - Exqlite.Connection
  - How are pooled connections going to work? Since sqlite3 doesn't allow for simultaneous access. We would need to check if the write ahead log is enab

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Connection.html#connect/1
  Exqlite.Connection.connect/1 - Part 2
  * `:foreign_keys` - Sets if foreign key checks should be enforced or not. Can be `:on` or `:off`. Default is `:on`. * `:cache_size` - Sets the cache s

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3.html#open/2-options
  Options - Exqlite.Sqlite3.open/2
  * `:mode` - controls the flags for sqlite3_open_v2 (see https://www.sqlite.org/c3ref/c_open_autoproxy.html). Defaults to `[:readwrite, :create]` (open

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3.html#set_authorizer/2-examples
  Examples - Exqlite.Sqlite3.set_authorizer/2
  # Block ATTACH and DETACH (prevent cross-database reads) :ok = Sqlite3.set_authorizer(conn, [:attach, :detach]) # Clear the authorizer :ok = Sqlite3.s

? exqlite	https://exqlite.hexdocs.pm/0.39.0/changelog.html#v0-38-0
  v0.38.0 - Changelog
  - added: Finer-grained `:mode` support when opening databases (e.g. `[:readwrite]` for read/write without implicit CREATE, `[:readwrite, :create]`). T

? exqlite	https://exqlite.hexdocs.pm/0.39.0/readme.html#caveats
  Caveats - Readme
  * Prepared statements are not cached. * Prepared statements are not immutable. You must be careful when manipulating statements and binding values to 


## avoid database is locked errors under concurrent writes
<!-- concept -->

y ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-differences-between-sqlite-and-ecto-sqlite-defaults
  Differences between SQLite and Ecto SQLite defaults - Ecto.Adapters.SQLite3
  For the most part, the defaults we provide above match the defaults that SQLite usually ships with. However, SQLite has conservative defaults due to i

y ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-transaction-mode
  Transaction mode - Ecto.Adapters.SQLite3
  By default, [SQLite transactions][8] run in `DEFERRED` mode. However, in web applications with a balanced load of reads and writes, using `IMMEDIATE` 

y ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-provided-options
  Provided options - Ecto.Adapters.SQLite3 - Part 2
  Depending on the database size, `:incremental` may be beneficial. * `:locking_mode` - Defaults to `:normal`. Allowed values are `:normal` or `:exclusi

n ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-in-memory-robustness
  In memory robustness - Ecto.Adapters.SQLite3
  When using the Ecto SQLite3 adapter with the database set to `:memory` it is possible that a crash in a process performing a query in the Repo will ca

n ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-async-sandbox-testing
  Async Sandbox testing - Ecto.Adapters.SQLite3
  The Ecto SQLite3 adapter does not support async tests when used with `Ecto.Adapters.SQL.Sandbox`. This is due to SQLite only allowing up one write tra

n ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-handling-foreign-key-constraints-in-changesets
  Handling foreign key constraints in changesets - Ecto.Adapters.SQLite3
  Unfortunately, unlike other databases, SQLite3 does not provide the precise name of the constraint violated, but only the columns within that constrai

? ecto_sqlite3	https://ecto-sqlite3.hexdocs.pm/0.24.1/Ecto.Adapters.SQLite3.html#module-case-sensitivity
  Case sensitivity - Ecto.Adapters.SQLite3
  Case sensitivity for `LIKE` is off by default, and controlled by the `:case_sensitive_like` option outlined above. However, for equality comparison, c


## declare a tool with a typed argument schema
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/ToolWithOutputSchema.html
  ToolWithOutputSchema
  A tool with output schema

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#tools
  Tools - Building a Server - Part 1
  A tool is a module that declares an input schema and implements `execute/2`: ```elixir defmodule MyApp.ProductSearch do @moduledoc "Search the product

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Tool.html#c:output_schema/0
  Anubis.Server.Component.Tool.output_schema/0
  Returns the JSON Schema for the tool's output structure. This schema defines the expected structure of the tool's output in the structuredContent fiel

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Tool.html#c:input_schema/0
  Anubis.Server.Component.Tool.input_schema/0
  Returns the JSON Schema for the tool's input parameters. This schema is used to validate client requests and generate documentation. The schema should

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/authorization.html#scope-enforcement
  Scope Enforcement - Authorization
  Declare required scopes on individual components: ```elixir defmodule MyApp.WriteFileTool do use Anubis.Server.Component, type: :tool, scopes: ["files

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/cheatsheet.html#tool-responses
  Tool responses - Cheatsheet
  ```elixir alias Anubis.Server.Response Response.text(Response.tool(), "plain text") Response.json(Response.tool(), %{any: "map"}) Response.structured(

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/ToolWithOutputSchema.html#get_schema/1
  ToolWithOutputSchema.get_schema/1
  # `get_schema`

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/ToolWithOutputSchema.html#mcp_schema/1
  ToolWithOutputSchema.mcp_schema/1
  # `mcp_schema`


## return an error result from a tool back to the client
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-client.html#calling-tools
  Calling tools - Building a Client
  ```elixir {:ok, response} = Anubis.Client.call_tool(MyApp.WeatherClient, "get_forecast", %{ "location" => "Tokyo", "days" => 5 }) ``` Requests return 

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Tool.html#c:execute/2-return-values
  Return Values - Anubis.Server.Component.Tool.execute/2
  - `{:reply, %Response{}, frame}` - Tool executed successfully - `{:noreply, frame}` - No reply needed - `{:error, %Error{}, frame}` - Tool failed with

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/cheatsheet.html#return-values
  Return values - Cheatsheet
  ```elixir {:ok, %Anubis.MCP.Response{result: map, is_error: false}} {:ok, %Anubis.MCP.Response{result: map, is_error: true}} # tool failed {:error, %A

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#responses
  Responses - Building a Server
  Build tool responses with `Anubis.Server.Response`. Start from `Response.tool()` and pipe into content builders: ```elixir Response.text(Response.tool

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#t:elicitation_callback/0
  Anubis.Client.elicitation_callback/0
  Elicitation callback function type. Called when the server sends an `elicitation/create` request. The callback receives the human-readable `message` a

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Tool.html#t:result/0
  Anubis.Server.Component.Tool.result/0
  # `result` ```elixir @type result() :: term() ```

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#error/2
  Anubis.Server.Response.error/2
  Mark a tool response as an error and add error message.

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#module-examples
  Examples - Anubis.Server.Response
  # Tool response Response.tool() |> Response.text("Result: " <> result) |> Response.build() # Resource response (uri and mime_type come from component)


## run a server that talks over standard input and output
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Transport.STDIO.html
  Anubis.Transport.STDIO
  A transport implementation that uses standard input/output. >

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Transport.STDIO.html
  Anubis.Server.Transport.STDIO
  STDIO transport implementation for MCP servers. This module handles communication with MCP clients via standard input/output streams, processing incom

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/transports.html#choosing-a-transport
  Choosing a transport - Transports
  **STDIO** runs the server as a subprocess of the client and speaks newline-delimited JSON over standard input and output. It is the default for local 

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/transports.html#serving-over-stdio
  Serving over STDIO - Transports
  ```elixir children = [ {MyApp.Server, transport: :stdio} ] ``` The process reads requests from stdin and writes responses to stdout. That has one prac

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Tool.html#t:t/0
  Anubis.Server.Component.Tool.t/0
  # `t` ```elixir @type t() :: %Anubis.Server.Component.Tool{ annotations: map() | nil, description: String.t() | nil, handler: module() | nil, input_sc

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/introduction.html#what-is-mcp
  What is MCP? - Introduction
  MCP is an open protocol that standardizes how AI applications talk to external systems. A server exposes capabilities in three forms: - **Tools** are 

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/transports.html#connecting-over-stdio
  Connecting over STDIO - Transports
  ```elixir {Anubis.Client, name: MyApp.MCPClient, transport: {:stdio, command: "python", args: ["-m", "my_server"]}, client_info: %{"name" => "MyApp", 

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/contributing.html#running-mcp-servers
  Running MCP Servers - Contributing to Anubis MCP
  For development and testing, you can use the provided MCP server implementations: ```bash # Start the Echo server (Python) # For now only support stdi


## restrict access to an HTTP endpoint using a bearer token
<!-- concept -->

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/authorize_requests.html
  Client request authorization
  # Client request authorization Once your authorization server setup done, you can deliver tokens that help __limiting access to HTTP services__. In or

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/authorize_requests.html#in-a-monolithic-application
  In a monolithic application - Client request authorization - Part 1
  In a monolith, you have access to __Boruta API__ (documented [here](https://hexdocs.pm/boruta/api-reference.html)) and can directly use it in order to

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.BearerToken.html
  Boruta.Oauth.BearerToken
  OAuth bearer token utilities Provide utilities to manipulate bearer tokens as stated in [RFC 6750 - Bearer token usage](https://datatracker.ietf.org/d

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.BearerToken.html#extract_token/1
  Boruta.Oauth.BearerToken.extract_token/1
  extract_token(conn) ``` @spec extract_token(conn :: Plug.Conn.t()) :: {:ok, access_token :: String.t()} | {:error, error :: Boruta.Oauth.Error.t()} ``

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/changelog.html#added-5
  Added - Changelog - Part 1
  - allow lower case bearer authorization header - prompt=none management for authorization code grant requests - store the previous code associated wit

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/pkce.html#flow-steps
  Flow steps - Notes for pkce extension - Part 3
  ```bash curl --location --request POST 'http://localhost:4000/oauth/token' \ --header 'Content-Type: application/x-www-form-urlencoded' \ --data-urlen

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/authorize_requests.html#in-a-microservice-environment
  In a microservice environment - Client request authorization
  With an authorization server set up, an __introspect endpoint__ is exposed to check token validity and provide security information as described in [R

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/create_client.html
  How to create an OAuth client — How to create an OAuth client
  ``` %Boruta.Ecto.Client{} |> Boruta.Ecto.Client.create_changeset(%{ id: id, # OAuth client_id secret: secret, # OAuth client_secret name: "A client", 


## prevent interception of the authorization code on a public client
<!-- concept -->

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/confidential_clients.html
  Notes about confidential clients
  # Notes about confidential clients This server manage confidential clients as stated in [OAuth 2.0 RFC](https://datatracker.ietf.org/doc/html/rfc6749)

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Client.html#public?/1
  Boruta.Oauth.Client.public?/1
  public?(client) ``` @spec public?(client :: t()) :: boolean() ```

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Client.html#t:t/0
  Boruta.Oauth.Client.t/0
  t() ``` @type t() :: %Boruta.Oauth.Client{ access_token_ttl: integer(), agent_token_ttl: integer(), authorization_code_ttl: integer(), authorization_r

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/pkce.html#flow-steps
  Flow steps - Notes for pkce extension - Part 1
  From the client perspective, who is in charge of sending the `code_challenge` and `code_challenge_method` among other fields during the request of the

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/changelog.html#fixed
  Fixed - Changelog
  - support for EdDSA signature algorithm - sd jwt credentials claims - clients did storage - revoke public client cache on update - presentations with 

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Ecto.Client.html#t:t/0
  Boruta.Ecto.Client.t/0
  t() ``` @type t() :: %Boruta.Ecto.Client{ __meta__: term(), access_token_ttl: integer(), agent_token_ttl: integer(), authorization_code_ttl: integer()

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.AuthorizationCodeRequest.html
  Boruta.Oauth.AuthorizationCodeRequest
  Authorization code request

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.PreauthorizationCodeRequest.html
  Boruta.Oauth.PreauthorizationCodeRequest
  Preauthorization code request


## keep some shared context between consecutive chunks
<!-- concept -->

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/readme.html#options
  Options - TextChunker: Flexible Text Chunking for Elixir - Part 2
  - `chunk_size` (default: `2000`) - The maximum chunk size, as measured by the `get_chunk_size` function. Chunks will not exceed this maximum, but may 

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.Strategies.RecursiveChunk.html
  TextChunker.Strategies.RecursiveChunk - Part 2
  * Combines splits into chunks, aiming to get as close to the `chunk_size` as possible. * Employs `chunk_overlap` to ensure smooth transitions between 

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.html
  TextChunker
  Provides a high-level interface for text chunking, employing a configurable splitting strategy (defaults to recursive splitting). Manages options and 

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/readme.html#unicode-edge-cases
  Unicode Edge Cases - TextChunker: Flexible Text Chunking for Elixir
  Chunks keep emoji sequences, accented characters, and other multi-codepoint graphemes whole - a grapheme may be made up of several codepoints and many

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.Strategies.RecursiveChunk.html#split/2
  TextChunker.Strategies.RecursiveChunk.split/2
  Internal recursive chunking strategy. Use `TextChunker.split/2` for public API. Splits text using prioritized separators, respecting `chunk_size` limi

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.Strategies.RecursiveChunk.html#split/2-options
  Options - TextChunker.Strategies.RecursiveChunk.split/2
  * `:chunk_size` (integer) - Maximum chunk size * `:chunk_overlap` (integer) - Overlap between chunks * `:format` (atom) - Text format for separator se

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/readme.html#usage
  Usage - TextChunker: Flexible Text Chunking for Elixir
  Chunk your text using the `split` function: ```elixir text = "Your text to be split..." chunks = TextChunker.split(text) ``` This will chunk up your t


## get the visible text out of a parsed document
<!-- concept -->

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_document/1
  LazyHTML.from_document/1
  Parses an HTML document. This function expects a complete document, therefore if either of ` `, ` ` or ` ` tags is missing, it will be added, which ma

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#text/2-examples
  Examples - LazyHTML.text/2
  iex> lazy_html = LazyHTML.from_fragment(~S| Hello world |) iex> LazyHTML.text(lazy_html) "Hello world" iex> lazy_html = LazyHTML.from_fragment(~S| 1 2

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_fragment/1
  LazyHTML.from_fragment/1
  Parses a segment of an HTML document. As opposed to `from_document/1`, this function does not expect a full document and does not add any extra tags.

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html
  LazyHTML - Part 1
  Efficient parsing and querying of HTML documents. LazyHTML is designed around lazy HTML documents. Documents are parsed and kept natively in memory fo

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#text/2
  LazyHTML.text/2
  Returns the text content of all nodes in `lazy_html`.

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.Tree.html#t:html_text/0
  LazyHTML.Tree.html_text/0
  html_text() ``` @type html_text() :: String.t() ```

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_document/1-examples
  Examples - LazyHTML.from_document/1
  iex> LazyHTML.from_document(~S| Hello world! |) #LazyHTML< 1 node #1 Hello world! > iex> LazyHTML.from_document(~S| Hello world! |) #LazyHTML< 1 node 

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#to_tree/2-examples
  Examples - LazyHTML.to_tree/2
  iex> lazy_html = LazyHTML.from_document(~S| Page Hello world |) iex> LazyHTML.to_tree(lazy_html) [{"html", [], [{"head", [], [{"title", [], ["Page"]}]


## identify the type of an uploaded file from its contents
<!-- concept -->

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/readme.html
  GenMagic - Part 3
  ``` iex(1)> {:ok, pid} = Supervisor.start_link([{GenMagic.Server, name: :gen_magic}], strategy: :one_for_one) {:ok, #PID<0.199.0>} ``` Now we can ask 

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Server.html#perform/3
  perform/3
  perform(server_ref, path, timeout \\ 5000) Specs ``` perform(t(), Path.t(), timeout()) :: {:ok, GenMagic.Result.t()} | {:error, term()} ``` Determines

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Server.html
  GenMagic.Server - Part 1
  GenMagic.Server (GenMagic v1.1.1) Provides access to the underlying libmagic client, which performs file introspection. The Server needs to be supervi

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Result.html
  GenMagic.Result
  GenMagic.Result (GenMagic v1.1.1) Represents the results obtained from libmagic. Please note that this struct is only returned if the underlying check

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Result.html#t:t/0
  t/0
  t() Specs ``` t() :: %GenMagic.Result{ content: String.t(), encoding: String.t(), mime_type: String.t() } ``` Represents the result. Contains the MIME

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/api-reference.html
  API Reference
  API Reference GenMagic v1.1.1 Modules GenMagic Top-level namespace for GenMagic, the libmagic client for Elixir. GenMagic.Helpers Contains convenience


## server requests a completion from the client model, sampling create message
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#register_sampling_callback/2
  Anubis.Client.register_sampling_callback/2
  Registers a callback function to handle sampling requests from the server. The callback function will be called when the server sends a `sampling/crea

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.html#send_sampling_request/2
  Anubis.Server.send_sampling_request/2
  Sends a sampling/createMessage request to the client. This is an asynchronous operation. The response will be delivered to your `handle_sampling/3` ca

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-client.html#client-capabilities
  Client capabilities - Building a Client
  Some MCP features flow from server to client: sampling asks your client to run an LLM completion, roots lets the server ask which directories it may t

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Session.ServerRequests.html
  Anubis.Server.Session.ServerRequests
  Engine for server-initiated requests (sampling, roots, elicitation). Owns the lifecycle of requests the server sends to the client: capability validat

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#register_sampling_callback/2-callback-function
  Callback Function - Anubis.Client.register_sampling_callback/2
  The callback receives the sampling parameters and must return: - `{:ok, response_map}` - Where response_map contains: - `"role"` - Usually "assistant"

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Session.html
  Anubis.Server.Session
  Per-client MCP session process. Each Session is a GenServer that manages the lifecycle of a single MCP client connection. It handles protocol initiali

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.html#send_elicitation_request/3
  Anubis.Server.send_elicitation_request/3
  Sends an `elicitation/create` request to the client. Per the MCP 2025-06-18 specification, the server provides a human-readable `message` and a restri

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Session.ServerRequests.html#send_request/5
  Anubis.Server.Session.ServerRequests.send_request/5
  Sends a server-initiated request of the given kind to the client. Generates the request ID, arms the timeout timer, tracks the request in `state.serve


## check whether the connected client declared a capability before sending a server request
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.html#send_elicitation_request/3
  Anubis.Server.send_elicitation_request/3
  Sends an `elicitation/create` request to the client. Per the MCP 2025-06-18 specification, the server provides a human-readable `message` and a restri

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-client.html#client-capabilities
  Client capabilities - Building a Client
  Some MCP features flow from server to client: sampling asks your client to run an LLM completion, roots lets the server ask which directories it may t

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Session.ServerRequests.html#send_request/5
  Anubis.Server.Session.ServerRequests.send_request/5
  Sends a server-initiated request of the given kind to the client. Generates the request ID, arms the timeout timer, tracks the request in `state.serve

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#is_client_capability/1
  Anubis.Client.is_client_capability/1
  Guard to check if an atom is a valid client capability.

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#is_supported_capability/2
  Anubis.Client.is_supported_capability/2
  Guard to check if a capability is supported by checking map keys.

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Client.html#register_elicitation_callback/2
  Anubis.Client.register_elicitation_callback/2
  Registers a callback function to handle elicitation requests from the server. The client must advertise the `elicitation` capability during initializa

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-client.html#discovering-capabilities
  Discovering capabilities - Building a Client
  Once connected you can ask the server what it offers: ```elixir info = Anubis.Client.get_server_info(MyApp.WeatherClient) caps = Anubis.Client.get_ser

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Protocol.Behaviour.html#c:server_capabilities/1
  Anubis.Protocol.Behaviour.server_capabilities/1
  Shapes a server's declared capabilities for advertisement in this version. Takes the capabilities map declared by the server module and returns the su


## Building a Server
<!-- concept -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html
  Building a Server
  # Building a Server An MCP server exposes parts of your application to AI clients. In Anubis a server is one module that declares identity and capabil

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#resources
  Resources - Building a Server
  Resources give clients read access to data. Each resource has a URI and implements `read/2`: ```elixir defmodule MyApp.ConfigResource do @moduledoc "C

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-client.html
  Building a Client
  # Building a Client An MCP client connects your application to a server, whether that server is written in Elixir, Python, TypeScript, or anything els

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#tools
  Tools - Building a Server - Part 2
  ```elixir schema do field :query, :string, required: true, description: "Full text search query" field :sort, :enum, values: ["price", "name"], defaul

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#notifications
  Notifications - Building a Server
  Servers can push notifications to connected clients. Call these from inside server callbacks: ```elixir Anubis.Server.send_tools_list_changed() Anubis

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#descriptions
  Descriptions - Building a Server
  Clients pick tools by reading their descriptions, so treat them as part of your interface. By default a component's description is its `@moduledoc`. W

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/building-a-server.html#the-server-module
  The server module - Building a Server
  ```elixir defmodule MyApp.Server do use Anubis.Server, name: "my-app", version: "1.0.0", capabilities: [:tools, :resources, :prompts] component MyApp.

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#completion/0
  Anubis.Server.Response.completion/0
  Start building a completion response.


## Req.merge/2
<!-- symbol -->

? req	https://req.hexdocs.pm/0.7.2/Req.html#merge/2
  Req.merge/2
  Updates a request struct. See `new/1` for a list of available options. Also see `Req.Request` module documentation for more information on the underly

? req	https://req.hexdocs.pm/0.7.2/Req.html#merge/2-examples
  Examples - Req.merge/2
  iex> req = Req.new(base_url: "https://httpbin.org") iex> req = Req.merge(req, auth: {:basic, "alice:secret"}) iex> req.options[:base_url] "https://htt

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#merge_options/2
  Req.Request.merge_options/2
  Merges given options into the request.

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#merge_new_options/2
  Req.Request.merge_new_options/2
  Merges given options into the request unless they are already set.

? req	https://req.hexdocs.pm/0.7.2/changelog.html#v0-4-12-2024-03-06
  v0.4.12 (2024-03-06) - CHANGELOG
  * [`Req`]: Add response body streaming via `into: :self`, [`Req.parse_message/2`], and `Req.cancel_async_response/1`. * [`Req`]: Deprecate `Req.update

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#merge_options/2-examples
  Examples - Req.Request.merge_options/2
  iex> req = Req.new(auth: {:basic, "alice:secret"}, http_errors: :raise) iex> req = Req.Request.merge_options(req, auth: {:bearer, "abcd"}, base_url: "

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#merge_new_options/2-examples
  Examples - Req.Request.merge_new_options/2
  iex> req = Req.new(auth: {:basic, "alice:secret"}) iex> req.options %{auth: {:basic, "alice:secret"}} iex> req = Req.Request.merge_new_options(req, au

? req	https://req.hexdocs.pm/0.7.2/changelog.html#full-changelog
  Full CHANGELOG - CHANGELOG - Part 3
  * [`retry`]: Support `retry: &fun/2`. The function receives `request, response_or_exception` and returns either: * `true` - retry with the default del


## Req.new/2
<!-- symbol -->

? req	https://req.hexdocs.pm/0.7.2/Req.html#new/2
  Req.new/2
  Returns a new request struct with built-in steps. See `request/2`, `run/2`, as well as `get/2`, `post/2`, and similar functions for making requests. A

? req	https://req.hexdocs.pm/0.7.2/Req.html#new/2-examples
  Examples - Req.new/2
  iex> req = Req.new(url: "https://elixir-lang.org") iex> req.method :get iex> URI.to_string(req.url) "https://elixir-lang.org" With a url and options: 

? req	https://req.hexdocs.pm/0.7.2/Req.html#new/2-options
  Options - Req.new/2 - Part 6
  If the request is sent using HTTP/1, an extra process is spawned to consume messages from the underlying socket. On both HTTP/1 and HTTP/2 the message

? req	https://req.hexdocs.pm/0.7.2/Req.html#request!/2
  Req.request!/2
  Makes an HTTP request and returns a response or raises an error. See `new/1` for a list of available options. Also see `run!/2` for a similar function

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#new/1
  Req.Request.new/1
  Returns a new request struct.

? req	https://req.hexdocs.pm/0.7.2/Req.html#post/2
  Req.post/2
  Makes a POST request and returns a response or an error. `request` can be one of: * an url (`String` or `URI`); * a `Keyword` options; * a `Req.Reques


## Req.Request.append_request_steps/2
<!-- symbol -->

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_request_steps/2
  Req.Request.append_request_steps/2
  Appends **request steps** to the existing request steps. See the ["Request Steps"](#module-request-steps) section in the module documentation for more

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_request_steps/2-examples
  Examples - Req.Request.append_request_steps/2
  Req.Request.append_request_steps(request, noop: fn request -> request end, inspect: &IO.inspect/1 )

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#prepend_request_steps/2
  Req.Request.prepend_request_steps/2
  Prepends **request steps** to the existing request steps. See the ["Request Steps"](#module-request-steps) section in the module documentation for mor

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_error_steps/2-examples
  Examples - Req.Request.append_error_steps/2
  Req.Request.append_error_steps(request, noop: fn {request, exception} -> {request, exception} end, inspect: &IO.inspect/1 )

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_response_steps/2-examples
  Examples - Req.Request.append_response_steps/2
  Req.Request.append_response_steps(request, noop: fn {request, response} -> {request, response} end, inspect: &IO.inspect/1 )

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_response_steps/2
  Req.Request.append_response_steps/2
  Appends **response steps** to the existing response steps. See the ["Response and Error Steps"](#module-response-and-error-steps) section in the modul

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#append_error_steps/2
  Req.Request.append_error_steps/2
  Appends **error steps** to the existing error steps. See the ["Response and Error Steps"](#module-response-and-error-steps) section in the module docu

? req	https://req.hexdocs.pm/0.7.2/Req.Request.html#prepend_request_steps/2-examples
  Examples - Req.Request.prepend_request_steps/2
  Req.Request.prepend_request_steps(request, noop: fn request -> request end, inspect: &IO.inspect/1 )


## Exqlite.Sqlite3.step/2
<!-- symbol -->

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3.html#step/2
  Exqlite.Sqlite3.step/2
  # `step` ```elixir @spec step(db(), statement()) :: :done | :busy | {:row, row()} | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3.html#multi_step/2
  Exqlite.Sqlite3.multi_step/2
  # `multi_step` ```elixir @spec multi_step(db(), statement()) :: :busy | {:rows, [row()]} | {:done, [row()]} | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3NIF.html#step/2
  Exqlite.Sqlite3NIF.step/2
  # `step` ```elixir @spec step(db(), statement()) :: :done | :busy | {:row, row()} | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3.html#multi_step/3
  Exqlite.Sqlite3.multi_step/3
  # `multi_step` ```elixir @spec multi_step(db(), statement()) :: :busy | {:rows, [row()]} | {:done, [row()]} | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3NIF.html#multi_step/3
  Exqlite.Sqlite3NIF.multi_step/3
  # `multi_step` ```elixir @spec multi_step(db(), statement(), integer()) :: :busy | {:rows, [row()]} | {:done, [row()]} | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/Exqlite.Sqlite3NIF.html#set_progress_handler_steps/2
  Exqlite.Sqlite3NIF.set_progress_handler_steps/2
  # `set_progress_handler_steps` ```elixir @spec set_progress_handler_steps(db(), integer()) :: :ok | {:error, reason()} ```

? exqlite	https://exqlite.hexdocs.pm/0.39.0/readme.html#usage
  Usage - Readme
  The `Exqlite.Sqlite3` module usage is fairly straight forward. ```elixir # We'll just keep it in memory right now {:ok, conn} = Exqlite.Sqlite3.open("

? exqlite	https://exqlite.hexdocs.pm/0.39.0/changelog.html#v0-11-9
  v0.11.9 - Changelog
  - fixed: `step/2` typespec was specified incorrectly.


## vec_distance_cosine/2
<!-- symbol -->

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_distance_cosine/2
  SqliteVec.Ecto.Query.vec_distance_cosine/2
  Calculates the cosine distance between vectors a and b. Only valid for float32 or int8 vectors. Returns an error under the following conditions: - a o

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_distance_hamming/2
  SqliteVec.Ecto.Query.vec_distance_hamming/2
  Calculates the hamming distance between two bitvectors a and b. Only valid for bitvectors. Returns an error under the following conditions: - a or b a

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_distance_L2/2
  SqliteVec.Ecto.Query.vec_distance_L2/2
  Calculates the L2 euclidian distance between vectors a and b. Only valid for float32 or int8 vectors. Returns an error under the following conditions:

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_sub/2
  SqliteVec.Ecto.Query.vec_sub/2
  Subtracts every element in vector a with vector b, returning a new vector c. Both vectors must be of the same type and same length. Only float32 and i

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/getting_started.html#sample-usage
  Sample usage - Getting Started
  This example is taken directly from the original `sqlite-vec` [README](https://github.com/asg017/sqlite-vec/). First, we open a new connection, then w

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_add/2
  SqliteVec.Ecto.Query.vec_add/2
  Adds every element in vector a with vector b, returning a new vector c. Both vectors must be of the same type and same length. Only float32 and int8 v

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/readme.html
  README
  # SqliteVec [![Hex Package](https://img.shields.io/hexpm/v/sqlite_vec.svg?style=for-the-badge)](https://hex.pm/packages/sqlite_vec) [![Hex Docs](https

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Query.html#vec_normalize/1
  SqliteVec.Ecto.Query.vec_normalize/1
  Performs L2 normalization on the given vector. Only float32 vectors are currently supported. Returns an error if the input is an invalid vector or not


## SqliteVec.Float32.new/1
<!-- symbol -->

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html#new/1
  SqliteVec.Float32.new/1
  Creates a new vector from a vector, list, or tensor

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html#from_binary/1
  SqliteVec.Float32.from_binary/1
  Creates a new vector from its binary representation

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html#to_tensor/1
  SqliteVec.Float32.to_tensor/1
  Converts the vector to a tensor

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Ecto.Float32.html
  SqliteVec.Ecto.Float32
  `Ecto.Type` for `SqliteVec.Float32`

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html#to_list/1
  SqliteVec.Float32.to_list/1
  Converts the vector to a list

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html#to_binary/1
  SqliteVec.Float32.to_binary/1
  Converts the vector to its binary representation

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Bit.html#new/1
  SqliteVec.Bit.new/1
  Creates a new vector from a vector, list, or tensor

? sqlite_vec	https://sqlite-vec.hexdocs.pm/0.1.0/SqliteVec.Float32.html
  SqliteVec.Float32
  A vector struct for float32 vectors. Vectors are stored as binaries in little endian.


## LazyHTML.from_document/1
<!-- symbol -->

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_document/1
  LazyHTML.from_document/1
  Parses an HTML document. This function expects a complete document, therefore if either of ` `, ` ` or ` ` tags is missing, it will be added, which ma

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_document/1-examples
  Examples - LazyHTML.from_document/1
  iex> LazyHTML.from_document(~S| Hello world! |) #LazyHTML< 1 node #1 Hello world! > iex> LazyHTML.from_document(~S| Hello world! |) #LazyHTML< 1 node 

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_fragment/1
  LazyHTML.from_fragment/1
  Parses a segment of an HTML document. As opposed to `from_document/1`, this function does not expect a full document and does not add any extra tags.

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_tree/1
  LazyHTML.from_tree/1
  Builds a lazy HTML document from an Elixir tree data structure.

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#to_html/2-examples
  Examples - LazyHTML.to_html/2
  iex> lazy_html = LazyHTML.from_document(~S| Hello world! |) iex> LazyHTML.to_html(lazy_html) " Hello world! " iex> lazy_html = LazyHTML.from_fragment(

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#from_fragment/1-examples
  Examples - LazyHTML.from_fragment/1
  iex> LazyHTML.from_fragment(~S| Click me |) #LazyHTML< 1 node #1 Click me > iex> LazyHTML.from_fragment(~S| Hello world |) #LazyHTML< 3 nodes #1 Hello

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#to_tree/2-examples
  Examples - LazyHTML.to_tree/2
  iex> lazy_html = LazyHTML.from_document(~S| Page Hello world |) iex> LazyHTML.to_tree(lazy_html) [{"html", [], [{"head", [], [{"title", [], ["Page"]}]

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#to_tree/2
  LazyHTML.to_tree/2
  Builds an Elixir tree data structure representing the `lazy_html` document.


## LazyHTML.query/2
<!-- symbol -->

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#query/2
  LazyHTML.query/2
  Finds elements in `lazy_html` matching the given CSS selector. Since `lazy_html` may have multiple root nodes, the root nodes are included in the sear

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#query/2-examples
  Examples - LazyHTML.query/2
  iex> lazy_html = ...> LazyHTML.from_fragment(""" ...> ...> Hello ...> world ...> ...> """) iex> LazyHTML.query(lazy_html, "span") #LazyHTML< 2 nodes (

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#query_by_id/2
  LazyHTML.query_by_id/2
  Finds elements in `lazy_html` matching the given id. This function is similar to `query/2`, but it accepts unescaped id string. Note that while techni

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#query_by_id/2-examples
  Examples - LazyHTML.query_by_id/2
  iex> lazy_html = ...> LazyHTML.from_fragment(""" ...> ...> Hello ...> world ...> ...> """) iex> LazyHTML.query_by_id(lazy_html, "hello") #LazyHTML< 1 

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html
  LazyHTML - Part 1
  Efficient parsing and querying of HTML documents. LazyHTML is designed around lazy HTML documents. Documents are parsed and kept natively in memory fo

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#nth_child/1-examples
  Examples - LazyHTML.nth_child/1
  iex> lazy_html = LazyHTML.from_fragment(~S| 1 2 |) iex> spans = LazyHTML.query(lazy_html, "span") iex> LazyHTML.nth_child(spans) [1, 2]

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#attribute/2-examples
  Examples - LazyHTML.attribute/2
  iex> lazy_html = ...> LazyHTML.from_fragment(""" ...> ...> Hello ...> world ...> ! ...> ...> """) iex> spans = LazyHTML.query(lazy_html, "span") iex> 

? lazy_html	https://lazy-html.hexdocs.pm/0.1.12/LazyHTML.html#parent_node/1-examples
  Examples - LazyHTML.parent_node/1
  iex> lazy_html = LazyHTML.from_fragment(~S| Hello world |) iex> spans = LazyHTML.query(lazy_html, "span") iex> LazyHTML.parent_node(spans) #LazyHTML< 


## TextChunker.split/2
<!-- symbol -->

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.html#split/2
  TextChunker.split/2
  Splits the provided text into a list of `%Chunk{}` structs.

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.ChunkerBehaviour.html#c:split/2
  TextChunker.ChunkerBehaviour.split/2
  # `split` ```elixir @callback split(text :: binary(), opts :: keyword()) :: [TextChunker.Chunk.t()] ``` --- *Consult [api-reference.md](api-reference.

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.html#split/2-examples
  Examples - TextChunker.split/2
  ```elixir iex> long_text = "This is a very long text that needs to be split into smaller pieces for easier handling." iex> TextChunker.split(long_text

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.Strategies.RecursiveChunk.html#split/2
  TextChunker.Strategies.RecursiveChunk.split/2
  Internal recursive chunking strategy. Use `TextChunker.split/2` for public API. Splits text using prioritized separators, respecting `chunk_size` limi

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/readme.html#usage
  Usage - TextChunker: Flexible Text Chunking for Elixir
  Chunk your text using the `split` function: ```elixir text = "Your text to be split..." chunks = TextChunker.split(text) ``` This will chunk up your t

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.Strategies.RecursiveChunk.html#split/2-options
  Options - TextChunker.Strategies.RecursiveChunk.split/2
  * `:chunk_size` (integer) - Maximum chunk size * `:chunk_overlap` (integer) - Overlap between chunks * `:format` (atom) - Text format for separator se

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/readme.html#your-text-to-be-split
  Your text to be split - TextChunker: Flexible Text Chunking for Elixir
  Let's split your text up properly! """ opts = [chunk_size: 10, chunk_overlap: 5, format: :markdown] chunks = TextChunker.split(text, opts) ```

? text_chunker	https://text-chunker.hexdocs.pm/0.7.0/TextChunker.html
  TextChunker
  Provides a high-level interface for text chunking, employing a configurable splitting strategy (defaults to recursive splitting). Manages options and 


## Anubis.Server.Response.json/3
<!-- symbol -->

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#json/3
  Anubis.Server.Response.json/3
  Add JSON-encoded content to a tool response. This is a convenience function that automatically encodes data as JSON and adds it as text content. Usefu

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#json/3-parameters
  Parameters - Anubis.Server.Response.json/3
  * `response` - A tool response struct * `data` - Any JSON-encodable data structure

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#json/3-examples
  Examples - Anubis.Server.Response.json/3
  iex> Response.tool() |> Response.json(%{status: "ok", count: 42}) %Response{ type: :tool, content: [%{"type" => "text", "text" => "{\"status\":\"ok\",

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#text/3-parameters
  Parameters - Anubis.Server.Response.text/3
  * `response` - A tool or resource response struct * `text` - The text content

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#structured/2
  Anubis.Server.Response.structured/2
  Set structured content for a tool response. This adds structured JSON content that conforms to the tool's output schema. For backward compatibility, t

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Component.Resource.html#c:read/2-building-responses
  Building Responses - Anubis.Server.Component.Resource.read/2
  Use `Response.resource/0` to create a resource response, then set content with the appropriate builder: - `Response.text/2` for text content (plain te

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#description/2-parameters
  Parameters - Anubis.Server.Response.description/2
  * `response` - A resource response struct * `desc` - Description of the resource

? anubis_mcp	https://anubis-mcp.hexdocs.pm/1.14.0/Anubis.Server.Response.html#error/2-parameters
  Parameters - Anubis.Server.Response.error/2
  * `response` - A tool response struct * `message` - The error message


## perform/3
<!-- symbol -->

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Pool.html#c:perform/3
  perform/3
  perform(name, arg2, list) Specs ``` perform(name(), Path.t(), [perform_option()]) :: {:ok, GenMagic.Result.t()} | {:error, term()} ```

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Server.html#perform/3
  perform/3
  perform(server_ref, path, timeout \\ 5000) Specs ``` perform(t(), Path.t(), timeout()) :: {:ok, GenMagic.Result.t()} | {:error, term()} ``` Determines

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Helpers.html#perform_once/2
  perform_once/2
  perform_once(path, options \\ []) Specs ``` perform_once(Path.t(), [GenMagic.Server.option()]) :: {:ok, GenMagic.Result.t()} | {:error, term()} ``` Ru

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Pool.html#t:perform_option/0
  perform_option/0
  perform_option() Specs ``` perform_option() :: {:timeout, timeout()} ```

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Helpers.html
  GenMagic.Helpers
  GenMagic.Helpers (GenMagic v1.1.1) Contains convenience functions for one-off use. Summary Functions perform_once(path, options \\ []) Runs a one-shot

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/readme.html
  GenMagic - Part 3
  ``` iex(1)> {:ok, pid} = Supervisor.start_link([{GenMagic.Server, name: :gen_magic}], strategy: :one_for_one) {:ok, #PID<0.199.0>} ``` Now we can ask 

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Pool.html
  GenMagic.Pool
  GenMagic.Pool behaviour (GenMagic v1.1.1) The GenMagic.Pool behaviour defines functions that must be implemented by each pool module which is added un

? gen_magic	https://gen-magic.hexdocs.pm/1.1.1/GenMagic.Server.html#t:option/0
  option/0
  option() Specs ``` option() :: {:name, atom() | :gen_statem.server_name()} | {:startup_timeout, timeout()} | {:process_timeout, timeout()} | {:recycle


## Boruta.Oauth.token/2
<!-- symbol -->

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.html#token/2
  Boruta.Oauth.token/2
  Process an token request as stated in [RFC 6749 - The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749). Triggers `token_success

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Token.html
  Boruta.Oauth.Token
  OAuth access token and code schema and utilities

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.TokenApplication.html#c:token_error/2
  Boruta.Oauth.TokenApplication.token_error/2
  This function will be triggered in case of failure invoking `Boruta.Oauth.token/2`

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Token.html#userinfo/1
  Boruta.Oauth.Token.userinfo/1
  userinfo(token)

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Application.html#c:token_error/2
  Boruta.Oauth.Application.token_error/2
  This function will be triggered in case of failure invoking `Boruta.Oauth.token/2`

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Application.html#c:token_success/2
  Boruta.Oauth.Application.token_success/2
  This function will be triggered in case of success invoking `Boruta.Oauth.token/2`

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.TokenApplication.html#c:token_success/2
  Boruta.Oauth.TokenApplication.token_success/2
  This function will be triggered in case of success invoking `Boruta.Oauth.token/2`

? boruta	https://boruta.hexdocs.pm/3.0.0-beta.4/Boruta.Oauth.Authorization.AccessToken.html
  Boruta.Oauth.Authorization.AccessToken
  Check against given params and return the corresponding access token
