defmodule CcxtExtract.TaskHelpers do
  @moduledoc """
  Shared test helpers for capturing Mix task output.

  Import in integration tests that need to run Mix tasks and assert on their output:

      import CcxtExtract.TaskHelpers
  """

  @doc """
  Runs a Mix task module and returns its shell output as a string.

  Temporarily swaps Mix.shell to `Mix.Shell.Process` so that `Mix.shell().info/1`
  messages are sent as process messages, then collects them into a joined string.
  """
  @spec run_task_capturing_output(module(), list()) :: String.t()
  def run_task_capturing_output(task_module, args \\ []) do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      task_module.run(args)
      collect_shell_output()
    after
      Mix.shell(original_shell)
    end
  end

  @receive_timeout_ms 100

  @doc false
  # Collects all {:mix_shell, :info|:error, [msg]} messages until no more arrive
  # within the timeout window. Implementation detail of run_task_capturing_output/2.
  @spec collect_shell_output(list()) :: String.t()
  def collect_shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_shell_output([msg | acc])
      {:mix_shell, :error, [msg]} -> collect_shell_output([msg | acc])
    after
      @receive_timeout_ms -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
