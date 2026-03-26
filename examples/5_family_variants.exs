# Analyze exchange family variants — which methods does each variant override?
#
# Usage: mix run examples/5_family_variants.exs [base_exchange]
# Default: binance (shows binance, binancecoinm, binanceus, binanceusdm)

base = List.first(System.argv()) || "binance"

# Find all variant files
all_ts = Path.wildcard("priv/ccxt/ts/src/#{base}*.ts")
all_pro = Path.wildcard("priv/ccxt/ts/src/pro/#{base}*.ts")
files = (all_ts ++ all_pro) |> Enum.reject(&String.contains?(&1, "abstract")) |> Enum.sort()

if Enum.empty?(files) do
  IO.puts("No files found for #{base}.")
  IO.puts("Run: git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt")
  IO.puts("Then: cd priv/ccxt && git sparse-checkout set ts/src")
  System.halt(1)
end

IO.puts("=== #{base} family ===\n")

extract_class = fn path ->
  source = File.read!(path)

  case OXC.parse(source, Path.basename(path)) do
    {:ok, ast} ->
      export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

      if export && export.declaration && export.declaration.body do
        class = export.declaration
        class_name = if class.id, do: class.id.name, else: "anonymous"

        superclass =
          cond do
            is_nil(class.superClass) -> "?"
            Map.has_key?(class.superClass, :name) -> class.superClass.name
            true -> "?"
          end

        methods =
          class.body.body
          |> Enum.filter(&(&1.type == "MethodDefinition"))
          |> Enum.map(fn m ->
            %{
              name: m.key.name,
              async: m.value.async,
              params: length(m.value.params),
              stmts: length(m.value.body.body)
            }
          end)

        %{class: class_name, super: superclass, methods: methods, path: path}
      end

    _ ->
      nil
  end
end

results = files |> Enum.map(extract_class) |> Enum.reject(&is_nil/1)

# Find base class methods
base_class = Enum.find(results, &(&1.class == base))
base_methods = if base_class, do: MapSet.new(base_class.methods, & &1.name), else: MapSet.new()

for r <- results do
  short = String.replace(r.path, "priv/ccxt/ts/src/", "")
  IO.puts("#{short}")
  IO.puts("  class #{r.class} extends #{r.super}")
  IO.puts("  #{length(r.methods)} methods")

  if r.class != base && MapSet.size(base_methods) > 0 do
    overrides = Enum.filter(r.methods, &MapSet.member?(base_methods, &1.name))
    new_methods = Enum.reject(r.methods, &MapSet.member?(base_methods, &1.name))

    if length(overrides) > 0 do
      IO.puts("  Overrides: #{Enum.map_join(overrides, ", ", & &1.name)}")
    end

    if length(new_methods) > 0 do
      IO.puts("  New: #{Enum.map_join(new_methods, ", ", & &1.name)}")
    end
  end

  IO.puts("")
end
