defmodule CcxtExtract.WsAuth do
  @moduledoc """
  Extract and derive per-exchange WebSocket authentication flow.

  Before a consumer can open a *private* WS stream it must authenticate the
  connection. CCXT models this in each Pro class
  (`priv/ccxt/ts/src/pro/<id>.ts`) as an `async authenticate(...)` method.
  Across the 110+ exchanges that method takes one of a few shapes:

    * **sign-in message** — the method builds a request object and sends it
      over the socket via `this.watch(...)` / `client.send(...)`. The object
      carries an `op` (bybit `'auth'`, okx `'login'`) or `method`
      (deribit `'public/auth'`, derive `'public/login'`) discriminant.
    * **url param** — credentials (typically a REST-acquired `listenKey`)
      are appended to the WS URL; no message is sent. binance's futures
      user-data stream is the canonical case.
    * **header** — an HTTP header on the WS upgrade request. Named here for
      completeness; no CCXT exchange currently uses it.

  ## Two roles

  This module is both an **extractor** and a **derivation**, mirroring
  `CcxtExtract.WsHeartbeat`:

    * Extractor (`extract/0`, `write!/2` via `CcxtExtract.OXCExtractor`) —
      parses every `pro/*.ts` into raw, inheritance-free facts written to
      `priv/discoveries/ws_auth.json`. Each entry records only what its own
      file's `authenticate` method states.
    * Derivation (`build/2`) — projects one raw entry plus the full
      discovery lookup into the consumer-facing `websocket.auth` section,
      resolving `extends`-chain inheritance and classifying the mechanism.

  ## Raw probes, not heuristics

  `ws_auth.json` stores structural facts read straight off the
  `authenticate` method AST — does it define a request object literal, does
  it call a socket-send method, does it touch `listenKey`, which
  `this.<credential>` fields it reads. `build/2` is then a *total,
  structural* classifier over those probes. An `authenticate` method that
  matches no known shape lands in `unknown` with
  `unresolved_reason: "auth_not_classifiable"` rather than being forced
  into a category. A wrong classification is fixed by adding a raw probe,
  never by tuning a heuristic.

  ## Local-`const` resolution

  okx writes `{ 'op': operation }` where `const operation = 'login'` sits a
  few lines up. The extractor scans the method body for
  `const/let <name> = <string-literal>` declarators and resolves
  identifier-valued `op`/`method` against that map. This is deterministic
  source-binding resolution — genuine extraction, not interpretation.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.WsAuth.extract()
      CcxtExtract.WsAuth.write!(exchanges)

      auth = CcxtExtract.WsAuth.build(entry, ws_auth_lookup)
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_auth.json"

  @mechanisms ~w(sign_in_message url_param header unknown none)
  @sources ~w(pro_authenticate none)
  @unresolved_reasons ~w(no_ws_support no_ws_auth auth_not_classifiable)
  @required_keys ~w(mechanism authenticate_defined message credentials
                    resolved_from source unresolved_reason)

  # `this.<name>` reads treated as credential inputs to the auth handshake.
  @credential_names ~w(apiKey secret password uid privateKey walletAddress)
  # Callee method names that send a message over the WS socket.
  @send_call_names ~w(watch watchMultiple watchPrivate watchPublic send)

  # --- Extractor callbacks ---

  @impl true
  @spec source_dir() :: String.t()
  def source_dir, do: Path.join(CcxtExtract.Paths.ts_src(), "pro")

  @impl true
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name, else: Path.rootname(filename)
      members = Enum.filter(class.body.body, &(&1.type == :method_definition))

      %{
        "id" => class_name,
        "class_name" => class_name,
        "file" => filename,
        "extends" => extends_name(class),
        "authenticate" => extract_authenticate(members)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_authenticate" => Enum.count(exchanges, &authenticate_defined?/1),
      "with_sign_in_message" => Enum.count(exchanges, &has_message?/1)
    }
  end

  # --- Extraction: class shape ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  # --- Extraction: authenticate method ---

  @spec extract_authenticate([map()]) :: map()
  defp extract_authenticate(members) do
    case Enum.find(members, &method_named?(&1, "authenticate")) do
      nil ->
        absent_authenticate()

      %{value: fn_expr} ->
        const_map = local_const_strings(fn_expr)

        %{
          "defined" => true,
          "async" => Map.get(fn_expr, :async, false) == true,
          "param_count" => length(Map.get(fn_expr, :params, [])),
          "credentials" => extract_credentials(fn_expr),
          "sends_message" => sends_message?(fn_expr),
          "url_param_signal" => url_param_signal?(fn_expr),
          "message" => extract_message(fn_expr, const_map)
        }
    end
  end

  @spec absent_authenticate() :: map()
  defp absent_authenticate do
    %{
      "defined" => false,
      "async" => false,
      "param_count" => 0,
      "credentials" => [],
      "sends_message" => false,
      "url_param_signal" => false,
      "message" => nil
    }
  end

  # Map of `const/let <name> = "<string literal>"` declarators in the method
  # body — used to resolve identifier-valued op/method discriminants.
  @spec local_const_strings(map()) :: %{String.t() => String.t()}
  defp local_const_strings(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :variable_declarator, id: %{type: :identifier, name: name}, init: init} -> {:keep, {name, init}}
      _ -> :skip
    end)
    |> Enum.reduce(%{}, fn {name, init}, acc ->
      case string_literal_value(init) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  # `this.<credential>` reads, deduped and sorted (a credential *set*).
  @spec extract_credentials(map()) :: [String.t()]
  defp extract_credentials(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{
        type: :member_expression,
        computed: false,
        object: %{type: :this_expression},
        property: %{type: :identifier, name: name}
      }
      when name in @credential_names ->
        {:keep, name}

      _ ->
        :skip
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # True when the method calls a socket-send method (`this.watch`, etc.).
  @spec sends_message?(map()) :: boolean()
  defp sends_message?(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{
        type: :call_expression,
        callee: %{type: :member_expression, computed: false, property: %{type: :identifier, name: name}}
      }
      when name in @send_call_names ->
        {:keep, true}

      _ ->
        :skip
    end)
    |> Kernel.!=([])
  end

  # True when the method references a `listenKey` identifier or string —
  # the structural marker of URL-parameter (listenKey) WS auth.
  @spec url_param_signal?(map()) :: boolean()
  defp url_param_signal?(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :identifier, name: "listenKey"} ->
        {:keep, true}

      %{type: type, value: value} when type in [:literal, :string_literal] and is_binary(value) ->
        if String.contains?(value, "listenKey"), do: {:keep, true}, else: :skip

      _ ->
        :skip
    end)
    |> Kernel.!=([])
  end

  # The sign-in request object literal (first object with an `op`/`method`
  # key), reduced to its discriminant values and top-level key set.
  @spec extract_message(map(), %{String.t() => String.t()}) :: map() | nil
  defp extract_message(fn_expr, const_map) do
    objects =
      OXC.collect(fn_expr, fn
        %{type: :object_expression} = node -> {:keep, node}
        _ -> :skip
      end)

    case Enum.find(objects, &auth_message_object?/1) do
      nil ->
        nil

      object ->
        %{
          "op" => discriminant_value(object, "op", const_map),
          "method" => discriminant_value(object, "method", const_map),
          "keys" => message_keys(object)
        }
    end
  end

  @spec auth_message_object?(map()) :: boolean()
  defp auth_message_object?(object) do
    keys = message_keys(object)
    "op" in keys or "method" in keys
  end

  # Top-level non-computed property keys, in source order.
  @spec message_keys(map()) :: [String.t()]
  defp message_keys(%{type: :object_expression, properties: properties}) do
    properties |> Enum.map(&property_key/1) |> Enum.reject(&is_nil/1)
  end

  # The literal value of a discriminant property — direct string literal, or
  # an identifier resolved through the local-`const` map. nil otherwise.
  @spec discriminant_value(map(), String.t(), %{String.t() => String.t()}) :: String.t() | nil
  defp discriminant_value(object, key, const_map) do
    case property_value_node(object, key) do
      %{type: type, value: value} when type in [:literal, :string_literal] and is_binary(value) ->
        value

      %{type: :identifier, name: name} ->
        Map.get(const_map, name)

      _ ->
        nil
    end
  end

  # --- Shared AST helpers ---

  @spec method_named?(map(), String.t()) :: boolean()
  defp method_named?(%{type: :method_definition, key: %{name: name}}, name), do: true
  defp method_named?(_member, _name), do: false

  @spec string_literal_value(map() | nil) :: String.t() | nil
  defp string_literal_value(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp string_literal_value(_node), do: nil

  # Value node of a non-computed property whose key resolves to `key_name`.
  @spec property_value_node(map(), String.t()) :: map() | nil
  defp property_value_node(%{type: :object_expression, properties: properties}, key_name) do
    Enum.find_value(properties, fn prop ->
      if Map.get(prop, :computed, false) == false and property_key(prop) == key_name do
        Map.get(prop, :value)
      end
    end)
  end

  @spec property_key(map()) :: String.t() | nil
  defp property_key(%{key: %{type: :identifier, name: n}}) when is_binary(n), do: n
  defp property_key(%{key: %{type: type, value: v}}) when type in [:literal, :string_literal] and is_binary(v), do: v
  defp property_key(_prop), do: nil

  @spec authenticate_defined?(map()) :: boolean()
  defp authenticate_defined?(entry), do: get_in(entry, ["authenticate", "defined"]) == true

  @spec has_message?(map()) :: boolean()
  defp has_message?(entry), do: is_map(get_in(entry, ["authenticate", "message"]))

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.auth` section.

  `lookup` is the full `%{id => raw_entry}` discovery map — used to resolve
  `extends`-chain inheritance (e.g. `binanceusdm` inherits `binance`'s
  `authenticate`). A `nil` entry (REST-only exchange with no Pro class)
  yields `none_record/0`. A Pro class that defines no `authenticate`
  anywhere in its chain (public-only WS) yields a `mechanism: "none"`
  record tagged `unresolved_reason: "no_ws_auth"`.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)

    case Enum.find(chain, &authenticate_defined?/1) do
      nil -> empty_record("no_ws_auth")
      auth_entry -> classify(auth_entry, chain)
    end
  end

  # `[self, parent, grandparent, ...]` by walking `extends` through the
  # discovery lookup. Stops when `extends` names a non-WS class (absent
  # from the lookup). The seen-set guards against cycles.
  @spec ancestry_chain(map(), map()) :: [map()]
  defp ancestry_chain(entry, lookup), do: ancestry_chain(entry, lookup, [], MapSet.new())

  @spec ancestry_chain(map() | nil, map(), [map()], MapSet.t()) :: [map()]
  defp ancestry_chain(nil, _lookup, acc, _seen), do: Enum.reverse(acc)

  defp ancestry_chain(entry, lookup, acc, seen) do
    id = entry["id"]

    if MapSet.member?(seen, id) do
      Enum.reverse(acc)
    else
      parent = entry["extends"] && Map.get(lookup, entry["extends"])
      ancestry_chain(parent, lookup, [entry | acc], MapSet.put(seen, id))
    end
  end

  # Project the most-derived `authenticate` in the chain into the record.
  # The whole `authenticate` sub-record (message / credentials /
  # url_param_signal) belongs to that one entry — overriding `authenticate`
  # in JS replaces it wholesale, so there is nothing to merge.
  @spec classify(map(), [map()]) :: map()
  defp classify(auth_entry, [head | _]) do
    auth = auth_entry["authenticate"]
    {mechanism, unresolved} = classify_mechanism(auth)

    %{
      "mechanism" => mechanism,
      "authenticate_defined" => true,
      "message" => auth["message"],
      "credentials" => auth["credentials"] || [],
      "resolved_from" => if(auth_entry["id"] == head["id"], do: "self", else: auth_entry["id"]),
      "source" => "pro_authenticate",
      "unresolved_reason" => unresolved
    }
  end

  # Total structural classifier: a request object literal means a sign-in
  # message; a bare `listenKey` reference means URL-parameter auth;
  # anything else is an honest `unknown`. `header` is never emitted — it is
  # reachable only via an override (see @moduledoc).
  @spec classify_mechanism(map()) :: {String.t(), String.t() | nil}
  defp classify_mechanism(auth) do
    cond do
      is_map(auth["message"]) -> {"sign_in_message", nil}
      auth["url_param_signal"] == true -> {"url_param", nil}
      true -> {"unknown", "auth_not_classifiable"}
    end
  end

  # --- Always-emit honest-empty record + closed-vocabulary exposers ---

  @doc """
  The `websocket.auth` record for an exchange with no WebSocket (Pro)
  class. `mechanism: "none"`, `unresolved_reason: "no_ws_support"` — mirrors
  `CcxtExtract.WsHeartbeat.none_record/0`.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record, do: empty_record("no_ws_support")

  @spec empty_record(String.t()) :: %{String.t() => term()}
  defp empty_record(reason) do
    %{
      "mechanism" => "none",
      "authenticate_defined" => false,
      "message" => nil,
      "credentials" => [],
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => reason
    }
  end

  @doc "Required keys of a `websocket.auth` record. For contract-test invariants."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `mechanism`. For contract-test invariants."
  @spec mechanisms() :: [String.t()]
  def mechanisms, do: @mechanisms

  @doc "Closed vocabulary for `source`. For contract-test invariants."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`. For contract-test invariants."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons
end
