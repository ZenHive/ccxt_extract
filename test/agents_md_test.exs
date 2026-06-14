defmodule CcxtExtract.AgentsMdTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.AgentsMd

  test "checked-in AGENTS.md and CLAUDE.md stay free of active cloud-agent guidance" do
    assert :ok = AgentsMd.check(File.cwd!())
  end

  test "forbidden_claude_imports/1 matches only @-import lines" do
    content = """
    @~/.claude/includes/linear-workflow.md
    prose mentioning linear-workflow.md is fine
    @~/.claude/includes/delegation-rules.md
    """

    assert ["linear-workflow.md", "delegation-rules.md"] ==
             AgentsMd.forbidden_claude_imports(content)
  end

  test "check/1 reports missing retired callout and forbidden guidance" do
    tmp = Path.join(System.tmp_dir!(), "agents_md_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(tmp, "CLAUDE.md"), "# ok\n")
    File.write!(Path.join(tmp, "AGENTS.md"), "Push-Back-vs-Fix-Locally Matrix\n")

    assert {:error, violations} = AgentsMd.check(tmp)
    assert "AGENTS.md missing retired callout" in violations

    assert Enum.any?(violations, &String.contains?(&1, "Push-Back-vs-Fix-Locally Matrix"))
  end
end
