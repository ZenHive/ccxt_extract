defmodule CcxtExtract.AgentsMd do
  @moduledoc """
  Guards generated reviewer docs against retired cloud-agent delegation guidance.

  Task 139: `AGENTS.md` is rendered from `CLAUDE.md` + `@`-imports. This repo
  retired `[CSR]`/`[CX]` cloud delegation; these checks fail if active guidance
  from the old portfolio includes re-enters the bundle.
  """

  @retired_callout "Cloud-agent delegation — retired in this repo"

  @forbidden_in_agents [
    "Cursor Delegation Flow",
    "Push-Back-vs-Fix-Locally Matrix",
    "NEVER PUSH TO A CLOUD-AGENT",
    "DON'T STEAL CLOUD-AGENT-DELEGATED TASKS",
    "Linear-as-Queue + Cloud-Agent Delegation",
    "marked with any cloud-agent delegation marker",
    "@~/.claude/includes/linear-workflow.md",
    "@~/.claude/includes/delegation-rules.md",
    "@~/.claude/includes/agent-dispatch.md"
  ]

  @forbidden_claude_imports [
    "linear-workflow.md",
    "delegation-rules.md",
    "agent-dispatch.md"
  ]

  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  @doc """
  Validates `AGENTS.md` and `CLAUDE.md` at `root` against retired cloud-agent guidance.
  """
  def check(root \\ File.cwd!()) do
    root = Path.expand(root)
    agents_path = Path.join(root, "AGENTS.md")
    claude_path = Path.join(root, "CLAUDE.md")

    with {:ok, agents} <- read_file(agents_path),
         {:ok, claude} <- read_file(claude_path) do
      claude_import_violations =
        claude
        |> forbidden_claude_imports()
        |> Enum.map(&"CLAUDE.md @-imports retired include: #{&1}")

      violations =
        []
        |> maybe_add(not String.contains?(agents, @retired_callout), "AGENTS.md missing retired callout")
        |> collect_forbidden(agents, "AGENTS.md", @forbidden_in_agents)
        |> Kernel.++(claude_import_violations)

      case violations do
        [] -> :ok
        list -> {:error, Enum.reverse(list)}
      end
    end
  end

  @spec forbidden_claude_imports(String.t()) :: [String.t()]
  @doc """
  Returns retired include filenames present as `@`-import lines in `content`.
  """
  def forbidden_claude_imports(content) do
    Enum.filter(@forbidden_claude_imports, fn suffix ->
      content =~ ~r/^@~\/\.claude\/includes\/#{Regex.escape(suffix)}\s*$/m
    end)
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, ["#{path}: #{inspect(reason)}"]}
    end
  end

  defp collect_forbidden(violations, content, label, patterns) do
    Enum.reduce(patterns, violations, fn pattern, acc ->
      if String.contains?(content, pattern) do
        ["#{label} contains retired cloud-agent guidance: #{inspect(pattern)}" | acc]
      else
        acc
      end
    end)
  end

  defp maybe_add(violations, true, message), do: [message | violations]
  defp maybe_add(violations, false, _message), do: violations
end
