defmodule CcxtExtract.RequestShape.VerbPath do
  @moduledoc """
  Task 70 — populate `endpoints` (HTTP verb + path template + path
  params) on every `structure.request_shape` record by walking
  `runtime.describe.api[<section>]`.

  # Patch count: 0/3. First patch migrates to priv/overrides/.
  # See ROADMAP.md § Phase 11 "Three-Strikes Rule".

  ## Output shape

  Returns a list of records:

      [
        %{
          "http_verb"     => "GET" | "POST" | "PUT" | "DELETE" | "PATCH",
          "path_template" => "<path-as-CCXT-wrote-it>",
          "path_params"   => [%{"name" => "<placeholder>", "source" => "params"}, ...]
        },
        ...
      ]

  The `path_template` preserves CCXT's literal path string verbatim:
  no leading slash is injected, no `{hostname}` substitution, no
  prefix injection (URL prefixes belong in
  `runtime.url_templates` — see `CcxtExtract.UrlTemplates`).
  Placeholders like `{order_id}` stay as written.

  `path_params` lists placeholders in left-to-right order. Today
  every placeholder's `"source"` is `"params"` because CCXT's
  `this.implodeParams(path, params)` always binds path placeholders
  to the call-args `params` map. The field is structured as a list of
  records to leave room for future binding modes (e.g. headers,
  per-call `since`/`limit` projections) without a schema break.

  ## Walk strategy

  CCXT's `describe.api` is a tree where leaf maps have HTTP-method
  keys (`get`, `post`, `put`, `delete`, `patch`) whose values are
  `%{path => rate_limit_cost}` maps (occasionally lists or rate-
  limit objects). Authenticated sections may be:

    * Flat — `api.private.get` is a leaf (okx, kucoin).
    * Nested — `api.private.spot.get` is the leaf, with `private`
      itself being an inner node (gate-style).
    * Dotted-name — the section name is `"spot.private"`,
      meaning `api.spot.private` is the entry point (htx-style).

  The walk:

    1. Resolve the section subtree by splitting `<name>` on `.` and
       applying `Map.get/2` step-by-step.
    2. Recursively descend any non-leaf inner map.
    3. At every leaf (a map with at least one HTTP-method key),
       enumerate the method's children and emit one endpoint record
       per `(method, path)` pair.

  Returns `nil` (with a closed-vocabulary reason on the parent
  record) when:

    * `describe_api` is not a map → `"no_describe_api"`.
    * The section subtree can't be resolved → `"section_not_in_api"`.

  An empty list `[]` (honest-empty) is emitted when the section
  resolves but contains no HTTP-method leaves — rare but legitimate
  for sections like `kucoin.uta` whose entries are runtime-defined.
  """

  @http_methods ~w(get post put delete patch)

  @http_method_set MapSet.new(@http_methods)

  @doc """
  Derive the `endpoints` list for one authenticated section.

  Returns one of:

    * `{:ok, [endpoint_map]}` — endpoint list (possibly empty)
    * `{:error, "no_describe_api"}` — `describe_api` not a map
    * `{:error, "section_not_in_api"}` — section path doesn't resolve

  The orchestrator pairs the error tag with the parent record's
  `unresolved_reason`.
  """
  @spec derive(map() | nil, String.t()) ::
          {:ok, [map()]} | {:error, String.t()}
  def derive(describe_api, section) when is_binary(section) do
    case resolve_section(describe_api, section) do
      :no_api -> {:error, "no_describe_api"}
      :not_found -> {:error, "section_not_in_api"}
      {:ok, subtree} -> {:ok, walk_endpoints(subtree)}
    end
  end

  def derive(_, _), do: {:error, "no_describe_api"}

  # --- Section resolution ---

  defp resolve_section(api, _section) when not is_map(api), do: :no_api

  defp resolve_section(api, section) do
    keys = String.split(section, ".")

    case walk_keys(api, keys) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> :not_found
      :not_found -> :not_found
    end
  end

  defp walk_keys(value, []), do: {:ok, value}

  defp walk_keys(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> walk_keys(value, rest)
      :error -> :not_found
    end
  end

  defp walk_keys(_, _), do: :not_found

  # --- Tree walk ---

  # Walk any subtree, emitting endpoints for every HTTP-method leaf
  # encountered. Inner nodes (maps without HTTP-method keys) recurse
  # via their values.
  defp walk_endpoints(subtree) when is_map(subtree) do
    if has_http_method_key?(subtree) do
      collect_method_entries(subtree)
    else
      subtree
      |> Map.values()
      |> Enum.flat_map(&walk_endpoints/1)
    end
  end

  defp walk_endpoints(_), do: []

  defp has_http_method_key?(map) do
    Enum.any?(Map.keys(map), &MapSet.member?(@http_method_set, &1))
  end

  defp collect_method_entries(map) do
    Enum.flat_map(@http_methods, fn method ->
      case Map.get(map, method) do
        nil -> []
        entries -> entries_for_verb(String.upcase(method), entries)
      end
    end)
  end

  # `%{path => cost}` is the dominant shape; `[path1, path2, ...]`
  # also appears in older CCXT exchanges. Both flatten to one
  # endpoint per path.
  defp entries_for_verb(verb, entries) when is_map(entries) do
    entries
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&endpoint_record(verb, &1))
  end

  defp entries_for_verb(verb, entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&extract_list_path/1)
    |> Enum.map(&endpoint_record(verb, &1))
  end

  defp entries_for_verb(_verb, _other), do: []

  defp extract_list_path(path) when is_binary(path), do: [path]
  defp extract_list_path(%{"path" => path}) when is_binary(path), do: [path]
  defp extract_list_path(_), do: []

  defp endpoint_record(verb, path) do
    %{
      "http_verb" => verb,
      "path_template" => path,
      "path_params" => extract_path_params(path)
    }
  end

  # CCXT path placeholders are `{name}` strings. `this.implodeParams`
  # substitutes them at call time from the `params` map. Walk the
  # path string left-to-right, return one record per placeholder.
  @doc """
  Extract the ordered list of `{name}`-style path-param records from
  a path template string.

  Public for unit tests + the contract-test invariant — both want
  the same parsing rules.
  """
  @spec extract_path_params(String.t()) :: [map()]
  def extract_path_params(path) when is_binary(path) do
    ~r/\{([^{}]+)\}/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [name] -> %{"name" => name, "source" => "params"} end)
  end

  def extract_path_params(_), do: []
end
