# Parse a CCXT TypeScript exchange file and extract class info
#
# Usage: mix run examples/1_parse_exchange.exs [exchange]
# Default: binance

exchange = List.first(System.argv()) || "binance"
path = "priv/ccxt/ts/src/#{exchange}.ts"

if !File.exists?(path) do
  IO.puts("File not found: #{path}")
  IO.puts("Run: git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt")
  IO.puts("Then: cd priv/ccxt && git sparse-checkout set ts/src")
  System.halt(1)
end

source = File.read!(path)
{:ok, ast} = OXC.parse(source, "#{exchange}.ts")

export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))
class = export.declaration

class_name = if class.id, do: class.id.name, else: "anonymous"

superclass =
  cond do
    is_nil(class.superClass) -> "?"
    Map.has_key?(class.superClass, :name) -> class.superClass.name
    true -> "?"
  end

methods = Enum.filter(class.body.body, &(&1.type == "MethodDefinition"))
async_count = Enum.count(methods, & &1.value.async)

IO.puts("=== #{Path.basename(path)} ===")
IO.puts("Class: #{class_name} extends #{superclass}")
IO.puts("Methods: #{length(methods)} (#{async_count} async, #{length(methods) - async_count} sync)")
IO.puts("")

for m <- methods do
  params =
    Enum.map_join(m.value.params, ", ", fn p ->
      name = Map.get(p, :name) || get_in(p, [:left, :name]) || "?"

      type =
        case Map.get(p, :typeAnnotation) do
          nil ->
            ""

          ta ->
            t = get_in(ta, [:typeAnnotation, :typeName, :name]) || ta.typeAnnotation.type
            ": #{t}"
        end

      "#{name}#{type}"
    end)

  async = if m.value.async, do: "async ", else: ""
  stmts = length(m.value.body.body)
  IO.puts("  #{async}#{m.key.name}(#{params}) [#{stmts} stmts]")
end
