defmodule CcxtExtract.MethodDescriptors do
  @moduledoc """
  Extract unified-method descriptors from CCXT TypeScript source via OXC.

  A CCXT unified method carries two complementary axes that this extractor
  fuses into one descriptor per method:

    1. **TS signature** (structural source of truth) — the ordered parameter
       list with name, TypeScript type, optional flag, and default value,
       plus the return type. Read straight off the method's ESTree AST.
    2. **JSDoc overlay** (semantic overlay) — the leading `/** … */` block's
       `@description` prose, per-`@param` prose, `@returns` shape, and
       `@throws {ErrorClass}` entries. OXC does **not** surface comments on
       the AST (no `leadingComments`, no program-level `comments` array —
       verified at runtime), so the JSDoc half is recovered with a second
       pass: a byte slice of the source text immediately preceding the
       method node, parsed for tags.

  Both halves are provenance `raw` — the signature is read verbatim from the
  AST, the JSDoc verbatim from the source. The descriptor is **consumer
  neutral**: it does not encode any single client's arg-shape convention, so
  each downstream port maps the ordered params to its own calling convention.

  Each descriptor also carries `source` — the byte-for-byte slice of the
  method definition (signature + body) via the node's `.start`/`.end`
  offsets, no normalization — so the descriptor is self-verifying against the
  CCXT source it was derived from.

  ## Scope — which methods get a descriptor

  CCXT's unified methods are exactly the public instance methods that return a
  `Promise<…>` (every `fetchX`/`createX`/`cancelX`/… returns a Promise). The
  scope is purely structural — `!static`, non-computed, name not starting with
  `_`, return type `Promise<…>` — so a unified method that happens to lack its
  JSDoc block still gets a descriptor. Sync helpers (`parseOrder`, `sign`,
  `describe`) are excluded; they are owned by other extractors.

  ## Honest partial descriptors

  A descriptor never fabricates the semantic overlay. When the JSDoc block is
  absent entirely, `description`, `params_doc`, `returns`, and `errors` are
  `null` and `unresolved_reason` is `"no_jsdoc"`. When the JSDoc block is
  present but a particular tag is not (e.g. no `@throws`), the corresponding
  field is an honest empty value (`errors: []`) rather than `null` — we
  looked and found none, which is different from being unable to look.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.MethodDescriptors.extract()
      CcxtExtract.MethodDescriptors.write!(exchanges)
  """

  alias CcxtExtract.Methods

  require Logger

  @output_file "method_descriptors.json"

  @doc """
  Extract unified-method descriptors from every REST exchange `.ts` file.

  Scans `priv/ccxt/ts/src/*.ts`, parses each via OXC, and builds one
  per-exchange entry holding its unified-method descriptors. Returns
  `{:ok, exchanges, stats}` where `stats` has `:skipped` and `:errors` lists.
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      raise "CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first."
    end

    files = Path.wildcard(Path.join(ts_src, "*.ts"))

    if files == [] do
      raise "No .ts files found in #{ts_src}. CCXT source may be incomplete."
    end

    {exchanges, skipped, errors} =
      files
      |> Enum.map(&parse_file/1)
      |> CcxtExtract.OXCBatch.reduce_results()

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(exchanges, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Read and OXC-parse a single `.ts` file into a per-exchange descriptor entry.

  Threads the raw source alongside the AST (the JSDoc and `source` slices need
  the byte buffer), so it cannot reuse `OXCBatch.parse_file/2` which only
  forwards the AST. Returns `{:ok, entry}`, `{:skip, filename}` when there is
  no exported class, or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        case extract_from_ast(ast, source, filename) do
          nil -> {:skip, filename}
          entry -> {:ok, entry}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end

  @doc """
  Build a per-exchange descriptor entry from a parsed AST and its source.

  Finds the default-exported class and emits a descriptor for each unified
  method (see `unified_method?/1`). Descriptors are sorted by name so the
  output is deterministic. Returns `nil` when the file has no exported class
  body (e.g. a base or abstract module).
  """
  @spec extract_from_ast(map(), String.t(), String.t()) :: map() | nil
  def extract_from_ast(ast, source, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      descriptors =
        class.body.body
        |> Enum.filter(&unified_method?/1)
        |> Enum.map(&build_descriptor(&1, source))
        |> Enum.sort_by(& &1["name"])

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "descriptor_count" => length(descriptors),
        "descriptors" => descriptors
      }
    end
  end

  @doc """
  True when a class member is a CCXT unified method.

  A unified method is a public (`!static`, name not starting with `_`),
  non-computed instance `method_definition` whose return type is a
  `Promise<…>`. This is the structural surface every `fetchX`/`createX`/…
  shares; it deliberately excludes sync helpers (`parseOrder`, `sign`,
  `describe`) owned by other extractors.
  """
  @spec unified_method?(map()) :: boolean()
  def unified_method?(%{type: :method_definition} = member) do
    Map.get(member, :kind) == :method and
      Map.get(member, :static) != true and
      Map.get(member, :computed) != true and
      is_binary(name_of(member)) and
      not String.starts_with?(name_of(member), "_") and
      promise_return?(member.value)
  end

  def unified_method?(_), do: false

  @doc """
  Build a single unified-method descriptor from its AST node and the source.

  Fuses the TS-signature half (read from the AST) with the JSDoc overlay
  (sliced from `source` immediately before the node), and attaches the
  byte-for-byte `source` slice of the method definition.
  """
  @spec build_descriptor(map(), String.t()) :: map()
  def build_descriptor(method, source) do
    jsdoc = method |> leading_jsdoc(source) |> parse_jsdoc()

    %{
      "name" => name_of(method),
      "async" => method.value.async == true,
      "signature" => %{
        "params" => Enum.map(method.value.params, &signature_param(&1, source)),
        "return_type" => Methods.extract_return_type(method.value)
      },
      "description" => jsdoc.description,
      "params_doc" => jsdoc.params_doc,
      "returns" => jsdoc.returns,
      "errors" => jsdoc.errors,
      "source" => slice(source, method.start, method.end),
      "unresolved_reason" => jsdoc.unresolved_reason
    }
  end

  @doc """
  Write per-exchange descriptors to `priv/discoveries/method_descriptors.json`.

  Supported options mirror the other discovery extractors:

    * `:scope` — `:all` or `MapSet.t(String.t())` for merge-safe scoped writes
    * `:tier_scope` — `CcxtExtract.Scope.to_manifest_value/1` output, stamped
      into the envelope. Defaults to `"all"`.
    * `:output_path` — override the default discovery path
    * `:extracted_at` — override the ISO8601 timestamp

  The envelope carries `"provenance" => "raw"` — both descriptor halves are
  raw by construction. Routes through `CcxtExtract.AggregateWriter.write!/3`
  so scoped runs merge with the existing aggregate and `count`/stats are
  recomputed from the final merged entries.
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(exchanges, opts \\ []) do
    default_path = CcxtExtract.Paths.out(Path.join("discoveries", @output_file))
    output_path = Keyword.get(opts, :output_path, default_path)

    writer_opts = [
      entry_key: "exchanges",
      id_key: "id",
      scope: Keyword.get(opts, :scope, :all),
      stats_fn: &write_stats/1,
      tier_scope: Keyword.get(opts, :tier_scope, "all"),
      extra: %{"provenance" => "raw"}
    ]

    writer_opts =
      case Keyword.fetch(opts, :extracted_at) do
        {:ok, ts} -> Keyword.put(writer_opts, :extracted_at, ts)
        :error -> writer_opts
      end

    CcxtExtract.AggregateWriter.write!(output_path, exchanges, writer_opts)
  end

  @doc """
  Envelope stats: exchanges with at least one descriptor, and the grand total.
  """
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_descriptors" => Enum.count(exchanges, &(&1["descriptor_count"] > 0)),
      "total_descriptors" => Enum.sum(Enum.map(exchanges, & &1["descriptor_count"]))
    }
  end

  # --- TS signature half -------------------------------------------------

  # Build one signature param map: name, TS type, optional flag, default value.
  # The default value is the raw source slice of the assignment RHS (e.g.
  # "undefined", "{}", "[]") so it is provenance `raw` like everything else.
  defp signature_param(%{type: :identifier} = param, _source) do
    %{
      "name" => param.name,
      "type" => type_of(param),
      "optional" => Map.get(param, :optional) == true,
      "default" => nil
    }
  end

  defp signature_param(%{type: :assignment_pattern} = param, source) do
    left = param.left

    %{
      "name" => Map.get(left, :name) || "{destructured}",
      "type" => type_of(left),
      "optional" => true,
      "default" => slice(source, param.right.start, param.right.end)
    }
  end

  defp signature_param(%{type: :rest_element} = param, _source) do
    %{
      "name" => "...#{get_in(param, [:argument, :name]) || "args"}",
      "type" => Methods.extract_type_name(get_in(param, [:argument, :typeAnnotation, :typeAnnotation])),
      "optional" => false,
      "default" => nil
    }
  end

  defp signature_param(%{type: type}, _source) do
    %{
      "name" => "?:#{CcxtExtract.AstNormalize.atom_to_pascal(type)}",
      "type" => nil,
      "optional" => false,
      "default" => nil
    }
  end

  defp type_of(node) do
    Methods.extract_type_name(get_in(node, [:typeAnnotation, :typeAnnotation]))
  end

  defp promise_return?(function_node) do
    case Methods.extract_return_type(function_node) do
      "Promise" <> _ -> true
      _ -> false
    end
  end

  defp name_of(member), do: get_in(member, [:key, :name])

  # --- JSDoc overlay half ------------------------------------------------

  # Return the `/** … */` block immediately preceding the method, or nil.
  # OXC does not attach comments to AST nodes, so we slice the source text
  # before the node's start. A block counts only when nothing but whitespace
  # separates its closing `*/` from the method — otherwise it belongs to an
  # earlier construct.
  @spec leading_jsdoc(map(), String.t()) :: String.t() | nil
  defp leading_jsdoc(method, source) do
    before = binary_part(source, 0, method.start)
    trimmed = String.trim_trailing(before)

    if String.ends_with?(trimmed, "*/") and String.starts_with?(String.trim_leading(last_block(trimmed)), "/**") do
      last_block(trimmed)
    end
  end

  # The substring from the last `/**` to the end of `trimmed` (which ends at
  # `*/`). Returns "" when there is no `/**`, so the caller's `starts_with?`
  # guard rejects it.
  defp last_block(trimmed) do
    case :binary.matches(trimmed, "/**") do
      [] ->
        ""

      matches ->
        {start, _len} = List.last(matches)
        binary_part(trimmed, start, byte_size(trimmed) - start)
    end
  end

  @empty_jsdoc %{
    description: nil,
    params_doc: nil,
    returns: nil,
    errors: nil,
    unresolved_reason: "no_jsdoc"
  }

  @doc """
  Parse a JSDoc `/** … */` block into the descriptor's semantic overlay.

  Returns a map with `:description`, `:params_doc`, `:returns`, `:errors`, and
  `:unresolved_reason`. A `nil` block (no JSDoc found) yields the honest
  all-`nil` overlay with `unresolved_reason: "no_jsdoc"`. A present block with
  a missing tag yields an honest empty value for that tag (e.g. `errors: []`),
  never `nil`.

  ## Examples

      iex> CcxtExtract.MethodDescriptors.parse_jsdoc(nil).unresolved_reason
      "no_jsdoc"

      iex> doc = "/**\\n * @description fetch an order\\n * @throws {OrderNotFound} missing\\n */"
      iex> overlay = CcxtExtract.MethodDescriptors.parse_jsdoc(doc)
      iex> {overlay.description, overlay.errors}
      {"fetch an order", [%{"class" => "OrderNotFound", "description" => "missing"}]}
  """
  @spec parse_jsdoc(String.t() | nil) :: %{
          description: String.t() | nil,
          params_doc: %{optional(String.t()) => String.t()} | nil,
          returns: map() | nil,
          errors: [map()] | nil,
          unresolved_reason: String.t() | nil
        }
  def parse_jsdoc(nil), do: @empty_jsdoc

  def parse_jsdoc(block) when is_binary(block) do
    tags = block |> strip_comment_frame() |> split_tags()

    %{
      description: tag_value(tags, "description"),
      params_doc: params_doc(tags),
      returns: returns(tags),
      errors: errors(tags),
      unresolved_reason: nil
    }
  end

  # Strip `/**`, trailing `*/`, and each line's leading ` * ` decoration,
  # returning the list of de-decorated content lines.
  defp strip_comment_frame(block) do
    block
    |> String.replace_prefix("/**", "")
    |> String.replace_suffix("*/", "")
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.replace_prefix("*", "")
      |> String.trim_leading()
    end)
  end

  # Fold de-decorated lines into `[{tag, text}]`. A line starting `@word`
  # opens a tag; following non-`@` lines are continuation text appended to the
  # open tag. Text before the first tag is discarded (CCXT leads with `@method`).
  defp split_tags(lines) do
    {current, acc} = Enum.reduce(lines, {nil, []}, &accumulate_tag/2)
    current |> push_tag(acc) |> Enum.reverse()
  end

  defp accumulate_tag(line, {current, acc}) do
    case Regex.run(~r/^@(\w+)\s*(.*)$/, line) do
      [_, tag, rest] -> {{tag, [rest]}, push_tag(current, acc)}
      nil -> {append_continuation(current, line), acc}
    end
  end

  defp append_continuation(nil, _line), do: nil
  defp append_continuation({tag, texts}, line), do: {tag, texts ++ [line]}

  defp push_tag(nil, acc), do: acc

  defp push_tag({tag, texts}, acc) do
    [{tag, texts |> Enum.join(" ") |> String.trim()} | acc]
  end

  # First value for `name`, or nil. Empty strings collapse to nil so a bare
  # `@description` with no prose is honestly absent rather than "".
  defp tag_value(tags, name) do
    Enum.find_value(tags, fn
      {^name, value} -> blank_to_nil(value)
      _ -> nil
    end)
  end

  # `@param {type} name desc` / `@param {type} [name] desc` →
  # %{name => desc}. The TS signature half owns type/optional; the overlay
  # contributes per-param prose, keyed by the documented name.
  defp params_doc(tags) do
    docs =
      for {"param", value} <- tags, into: %{} do
        case Regex.run(~r/^(?:\{[^}]*\}\s*)?\[?([A-Za-z_$][\w.$]*)(?:=[^\]]*)?\]?\s*(.*)$/, value) do
          [_, name, desc] -> {name, blank_to_nil(desc)}
          _ -> {value, nil}
        end
      end

    docs
  end

  # `@returns {type} desc` → %{"type" => type, "description" => desc}, or nil
  # when there is no `@returns`/`@return` tag.
  defp returns(tags) do
    Enum.find_value(tags, fn
      {tag, value} when tag in ["returns", "return"] -> parse_typed(value)
      _ -> nil
    end)
  end

  # Each `@throws {ErrorClass} desc` → %{"class" => ..., "description" => ...}.
  # `[]` when the block has no `@throws` (looked, found none); the caller never
  # passes a nil block here (that path returns `@empty_jsdoc` upstream).
  defp errors(tags) do
    for {tag, value} <- tags, tag in ["throws", "throw"] do
      %{"type" => class, "description" => desc} = parse_typed(value)
      %{"class" => class, "description" => desc}
    end
  end

  # Split a `{Type} trailing description` tag body into type + description.
  defp parse_typed(value) do
    case Regex.run(~r/^\{([^}]*)\}\s*(.*)$/, value) do
      [_, type, desc] -> %{"type" => blank_to_nil(type), "description" => blank_to_nil(desc)}
      _ -> %{"type" => nil, "description" => blank_to_nil(value)}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(string) do
    case String.trim(string) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Byte-for-byte source slice between two OXC byte offsets.
  defp slice(source, start_offset, end_offset) do
    binary_part(source, start_offset, end_offset - start_offset)
  end
end
