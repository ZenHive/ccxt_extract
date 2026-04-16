defmodule CcxtExtract.JsonIO do
  @moduledoc """
  Canonical helper for reading and decoding JSON files.

  Replaces seven private `read_json/1` copies (three behavioral shapes) that
  were scattered across pipeline, analysis, and loader modules. Callers that
  previously raised on `Jason.DecodeError` now receive
  `{:error, {:invalid_json, _}}` and must handle it explicitly.

  > #### `:missing_input` semantics {: .info}
  >
  > `{:missing_input, path}` covers **every** `File.read` failure — `:enoent`,
  > `:eacces`, `:eisdir`, etc. — not only "file not found." The atom is kept
  > narrow on purpose so existing pattern matches (`{:error, {:missing_input,
  > ^path}}`) keep working; the underlying POSIX reason is dropped. Callers
  > that need to disambiguate permission/type errors should call
  > `File.read/1` directly.
  """

  @type read_error ::
          {:missing_input, Path.t()}
          | {:invalid_json, String.t()}

  @doc """
  Read and decode a JSON file.

  Returns `{:ok, decoded}`, `{:error, {:missing_input, path}}` when the file
  cannot be read (enoent, eacces, eisdir, …), or `{:error, {:invalid_json,
  detail}}` when the content is not valid JSON. Never raises.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec read_json(Path.t()) :: {:ok, term()} | {:error, read_error()}
  def read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        try do
          {:ok, Jason.decode!(content)}
        rescue
          e in Jason.DecodeError ->
            {:error, {:invalid_json, "#{path}: #{Exception.message(e)}"}}
        end

      {:error, _reason} ->
        {:error, {:missing_input, path}}
    end
  end

  @doc """
  Read and decode a JSON file, raising on failure.

  Raises `File.Error` when the file cannot be read and `Jason.DecodeError`
  when the content is not valid JSON.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec read_json!(Path.t()) :: term()
  def read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
