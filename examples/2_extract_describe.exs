# Extract describe() config object from a CCXT TS exchange file using OXC AST
#
# Usage: mix run examples/2_extract_describe.exs [exchange]
# Default: binance

exchange = List.first(System.argv()) || "binance"
path = Path.join(CcxtExtract.Paths.ts_src(), "#{exchange}.ts")

if !File.exists?(path) do
  IO.puts("File not found: #{path}")
  IO.puts("Run: git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt")
  IO.puts("Then: cd priv/ccxt && git sparse-checkout set ts/src")
  System.halt(1)
end

source = File.read!(path)
{:ok, ast} = OXC.parse(source, "#{exchange}.ts")

export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))
methods = Enum.filter(export.declaration.body.body, &(&1.type == "MethodDefinition"))
describe = Enum.find(methods, &(&1.key.name == "describe"))

# describe() returns this.deepExtend(super.describe(), { ... })
# The second argument is the big config object
config_obj =
  describe.value.body.body
  |> hd()
  |> Map.get(:argument)
  |> Map.get(:arguments)
  |> Enum.at(1)

# Recursive AST value extractor
extract = fn
  %{type: "Literal", value: v}, _r ->
    v

  %{type: "Identifier", name: "undefined"}, _r ->
    :undefined

  %{type: "Identifier", name: n}, _r ->
    {:ref, n}

  %{type: "ArrayExpression", elements: els}, r ->
    Enum.map(els, &r.(&1, r))

  %{type: "ObjectExpression", properties: props}, r ->
    Map.new(props, fn p ->
      key = Map.get(p.key, :name) || to_string(Map.get(p.key, :value, "?"))
      {key, r.(p.value, r)}
    end)

  %{type: "UnaryExpression", operator: "-", argument: %{value: v}}, _r ->
    -v

  %{type: "CallExpression"} = node, _r ->
    callee = get_in(node, [:callee, :property, :name]) || "unknown"
    args = Enum.map(node.arguments, fn a -> Map.get(a, :value, "?") end)
    {:call, callee, args}

  %{type: t}, _r ->
    {:ast, t}

  nil, _r ->
    nil
end

find_prop = fn props, name ->
  Enum.find(props, fn p ->
    (Map.get(p.key, :name) || Map.get(p.key, :value)) == name
  end)
end

props = config_obj.properties

# Show top-level keys
keys =
  Enum.map(props, fn p ->
    Map.get(p.key, :name) || to_string(Map.get(p.key, :value))
  end)

IO.puts("=== #{exchange} describe() ===")
IO.puts("Top-level keys (#{length(keys)}): #{inspect(keys)}\n")

# Extract key sections
for key <- ["id", "name", "certified", "pro", "rateLimit"] do
  case find_prop.(props, key) do
    nil -> :skip
    prop -> IO.puts("#{key}: #{inspect(extract.(prop.value, extract))}")
  end
end

IO.puts("")

# has
case find_prop.(props, "has") do
  nil ->
    IO.puts("has: not found")

  prop ->
    has = extract.(prop.value, extract)
    true_count = Enum.count(has, fn {_, v} -> v == true end)
    false_count = Enum.count(has, fn {_, v} -> v == false end)
    IO.puts("has: #{map_size(has)} keys (#{true_count} true, #{false_count} false)")
end

# exceptions
case find_prop.(props, "exceptions") do
  nil ->
    IO.puts("exceptions: not found")

  prop ->
    exc = extract.(prop.value, extract)

    for {category, mappings} <- exc do
      if is_map(mappings) do
        IO.puts("exceptions.#{category}: #{map_size(mappings)} codes")
      end
    end
end

# features
case find_prop.(props, "features") do
  nil ->
    IO.puts("features: not found")

  prop ->
    features = extract.(prop.value, extract)

    for {mt, caps} <- features do
      if is_map(caps) do
        IO.puts("features.#{mt}: #{map_size(caps)} methods")
      end
    end
end

# urls
case find_prop.(props, "urls") do
  nil ->
    IO.puts("urls: not found")

  prop ->
    urls = extract.(prop.value, extract)
    IO.puts("\nurls:")

    for {k, v} <- urls do
      display = if is_binary(v), do: v, else: "(#{if is_map(v), do: map_size(v), else: length(v)} entries)"
      IO.puts("  #{k}: #{display}")
    end
end
