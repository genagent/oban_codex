defmodule ObanCodex.Query do
  @moduledoc """
  Translate validated ObanCodex options into fresh or resumed Codex commands.

  Most callers use `ObanCodex.run/2`. This module is public for applications
  that want the same JSONL command adapter without outcome classification.
  """

  alias CodexWrapper.{Command, Config, Exec, ExecFork, ExecResume}
  alias ObanCodex.{Error, Query.Resume}

  @config_keys [:binary, :working_dir, :timeout, :verbose]

  @doc """
  Run a fresh turn, resume when `:session_id` is present, or fork when
  `:session_id` is present with `fork_session: true`.

  A fork runs `codex exec fork` through `CodexWrapper.ExecFork.fork/2`. The
  returned `%CodexWrapper.Result{}` carries the NEW thread id in its
  `thread.started` event, so `ObanCodex.session_id/1` reads the fork, never the
  source. A non-zero exit is returned as a `%Result{success: false}`, as for
  fresh and resumed turns. A CLI without `exec fork` returns an
  `%ObanCodex.Error{kind: :unsupported}`.
  """
  @spec run(String.t(), keyword()) ::
          {:ok, CodexWrapper.Result.t()} | {:error, ObanCodex.Error.t()}
  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    {config_opts, command_opts} = Keyword.split(opts, @config_keys)
    config = Config.new(config_opts)

    {fork?, command_opts} = Keyword.pop(command_opts, :fork_session, false)

    outcome =
      case {Keyword.pop(command_opts, :session_id), fork?} do
        {{nil, _exec_opts}, true} ->
          raise ArgumentError, ":fork_session requires :session_id"

        {{nil, exec_opts}, _fork?} ->
          execute(prompt, exec_opts, config)

        {{session_id, fork_opts}, true} ->
          fork(session_id, prompt, fork_opts, config)

        {{session_id, resume_opts}, _fork?} ->
          resume(session_id, prompt, resume_opts, config)
      end

    normalize_error(outcome)
  end

  defp execute(prompt, opts, config) do
    opts
    |> Enum.reduce(Exec.new(prompt), &apply_exec_option/2)
    |> Exec.json()
    |> Exec.execute(config)
  end

  defp resume(session_id, prompt, opts, config) do
    {output_schema, opts} = Keyword.pop(opts, :output_schema)
    {approval_policy, opts} = Keyword.pop(opts, :approval_policy)
    {search, opts} = Keyword.pop(opts, :search)

    resume =
      opts
      |> Enum.reduce(ExecResume.new(), &apply_resume_option/2)
      |> maybe_resume_approval(approval_policy)
      |> maybe_resume_search(search)
      |> ExecResume.json()

    command = %Resume{
      exec: resume,
      session_id: session_id,
      prompt: prompt,
      output_schema: output_schema
    }

    Command.run(Resume, command, config)
  end

  defp fork(session_id, prompt, opts, config) do
    {approval_policy, opts} = Keyword.pop(opts, :approval_policy)
    {search, opts} = Keyword.pop(opts, :search)

    session_id
    |> ExecFork.new()
    |> ExecFork.prompt(prompt)
    |> then(&Enum.reduce(opts, &1, fn option, fork -> apply_fork_option(option, fork) end))
    |> maybe_config(&ExecFork.config/2, approval_config(approval_policy))
    |> maybe_config(&ExecFork.config/2, search_config(search))
    |> ExecFork.fork(config)
    |> case do
      {:ok, %{result: result}} -> {:ok, result}
      # Keep a non-zero exit a result, matching fresh and resumed turns.
      {:error, {:exit, _code, result}} -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_error({:error, reason}), do: {:error, Error.from_reason(reason)}
  defp normalize_error(outcome), do: outcome

  defp apply_exec_option({:model, value}, exec), do: Exec.model(exec, value)
  defp apply_exec_option({:profile, value}, exec), do: Exec.profile(exec, value)
  defp apply_exec_option({:sandbox, value}, exec), do: Exec.sandbox(exec, value)

  defp apply_exec_option({:approval_policy, value}, exec),
    do: Exec.approval_policy(exec, value)

  defp apply_exec_option({:full_auto, true}, exec), do: Exec.full_auto(exec)

  defp apply_exec_option({:dangerously_bypass_approvals_and_sandbox, true}, exec),
    do: Exec.dangerously_bypass_approvals_and_sandbox(exec)

  defp apply_exec_option({:dangerously_bypass_hook_trust, true}, exec),
    do: Exec.dangerously_bypass_hook_trust(exec)

  defp apply_exec_option({:skip_git_repo_check, true}, exec),
    do: Exec.skip_git_repo_check(exec)

  defp apply_exec_option({:add_dir, values}, exec),
    do: Enum.reduce(List.wrap(values), exec, &Exec.add_dir(&2, &1))

  defp apply_exec_option({:search, value}, exec), do: Exec.search(exec, value)
  defp apply_exec_option({:ephemeral, true}, exec), do: Exec.ephemeral(exec)
  defp apply_exec_option({:output_schema, value}, exec), do: Exec.output_schema(exec, value)

  defp apply_exec_option({:output_last_message, value}, exec),
    do: Exec.output_last_message(exec, value)

  defp apply_exec_option({:images, values}, exec),
    do: Enum.reduce(values, exec, &Exec.image(&2, &1))

  defp apply_exec_option({:config_overrides, values}, exec),
    do: Enum.reduce(values, exec, &Exec.config(&2, &1))

  defp apply_exec_option({:enabled_features, values}, exec),
    do: Enum.reduce(values, exec, &Exec.enable(&2, &1))

  defp apply_exec_option({:disabled_features, values}, exec),
    do: Enum.reduce(values, exec, &Exec.disable(&2, &1))

  defp apply_exec_option({:strict_config, true}, exec), do: Exec.strict_config(exec)
  defp apply_exec_option({:ignore_user_config, true}, exec), do: Exec.ignore_user_config(exec)
  defp apply_exec_option({:ignore_rules, true}, exec), do: Exec.ignore_rules(exec)
  defp apply_exec_option({:color, value}, exec), do: Exec.color(exec, value)
  defp apply_exec_option({:oss, true}, exec), do: Exec.oss(exec)
  defp apply_exec_option({:local_provider, value}, exec), do: Exec.local_provider(exec, value)
  defp apply_exec_option({_key, nil}, exec), do: exec
  defp apply_exec_option({_key, false}, exec), do: exec

  defp apply_resume_option({:model, value}, resume), do: ExecResume.model(resume, value)
  defp apply_resume_option({:sandbox, value}, resume), do: ExecResume.sandbox(resume, value)
  defp apply_resume_option({:full_auto, true}, resume), do: ExecResume.full_auto(resume)

  defp apply_resume_option({:dangerously_bypass_approvals_and_sandbox, true}, resume),
    do: ExecResume.dangerously_bypass_approvals_and_sandbox(resume)

  defp apply_resume_option({:dangerously_bypass_hook_trust, true}, resume),
    do: ExecResume.dangerously_bypass_hook_trust(resume)

  defp apply_resume_option({:skip_git_repo_check, true}, resume),
    do: ExecResume.skip_git_repo_check(resume)

  defp apply_resume_option({:ephemeral, true}, resume), do: ExecResume.ephemeral(resume)

  defp apply_resume_option({:output_last_message, value}, resume),
    do: ExecResume.output_last_message(resume, value)

  defp apply_resume_option({:images, values}, resume),
    do: Enum.reduce(values, resume, &ExecResume.image(&2, &1))

  defp apply_resume_option({:config_overrides, values}, resume),
    do: Enum.reduce(values, resume, &ExecResume.config(&2, &1))

  defp apply_resume_option({:enabled_features, values}, resume),
    do: Enum.reduce(values, resume, &ExecResume.enable(&2, &1))

  defp apply_resume_option({:disabled_features, values}, resume),
    do: Enum.reduce(values, resume, &ExecResume.disable(&2, &1))

  defp apply_resume_option({:strict_config, true}, resume), do: ExecResume.strict_config(resume)

  defp apply_resume_option({:ignore_user_config, true}, resume),
    do: ExecResume.ignore_user_config(resume)

  defp apply_resume_option({:ignore_rules, true}, resume), do: ExecResume.ignore_rules(resume)

  # These are initial-turn-only in `codex exec resume`. The conversation has
  # already captured them, so worker defaults can safely remain on every job.
  defp apply_resume_option({key, _value}, resume)
       when key in [:profile, :add_dir, :color, :oss, :local_provider],
       do: resume

  defp apply_resume_option({_key, nil}, resume), do: resume
  defp apply_resume_option({_key, false}, resume), do: resume

  defp apply_fork_option({:model, value}, fork), do: ExecFork.model(fork, value)
  defp apply_fork_option({:sandbox, value}, fork), do: ExecFork.sandbox(fork, value)
  defp apply_fork_option({:full_auto, true}, fork), do: ExecFork.full_auto(fork)

  defp apply_fork_option({:dangerously_bypass_approvals_and_sandbox, true}, fork),
    do: ExecFork.dangerously_bypass_approvals_and_sandbox(fork)

  defp apply_fork_option({:dangerously_bypass_hook_trust, true}, fork),
    do: ExecFork.dangerously_bypass_hook_trust(fork)

  defp apply_fork_option({:skip_git_repo_check, true}, fork),
    do: ExecFork.skip_git_repo_check(fork)

  defp apply_fork_option({:ephemeral, true}, fork), do: ExecFork.ephemeral(fork)
  defp apply_fork_option({:output_schema, value}, fork), do: ExecFork.output_schema(fork, value)

  defp apply_fork_option({:output_last_message, value}, fork),
    do: ExecFork.output_last_message(fork, value)

  defp apply_fork_option({:images, values}, fork),
    do: Enum.reduce(values, fork, &ExecFork.image(&2, &1))

  defp apply_fork_option({:config_overrides, values}, fork),
    do: Enum.reduce(values, fork, &ExecFork.config(&2, &1))

  defp apply_fork_option({:enabled_features, values}, fork),
    do: Enum.reduce(values, fork, &ExecFork.enable(&2, &1))

  defp apply_fork_option({:disabled_features, values}, fork),
    do: Enum.reduce(values, fork, &ExecFork.disable(&2, &1))

  defp apply_fork_option({:strict_config, true}, fork), do: ExecFork.strict_config(fork)

  defp apply_fork_option({:ignore_user_config, true}, fork),
    do: ExecFork.ignore_user_config(fork)

  defp apply_fork_option({:ignore_rules, true}, fork), do: ExecFork.ignore_rules(fork)

  # `codex exec fork` rejects these. `ObanCodex.Args.new/1` refuses them on a
  # fork job; worker defaults may still carry them, and the forked history
  # already captured them, so they are dropped here as on resume.
  defp apply_fork_option({key, _value}, fork)
       when key in [:profile, :add_dir, :color, :oss, :local_provider],
       do: fork

  defp apply_fork_option({_key, nil}, fork), do: fork
  defp apply_fork_option({_key, false}, fork), do: fork

  defp maybe_resume_approval(resume, value),
    do: maybe_config(resume, &ExecResume.config/2, approval_config(value))

  defp maybe_resume_search(resume, value),
    do: maybe_config(resume, &ExecResume.config/2, search_config(value))

  defp maybe_config(command, _config_fun, nil), do: command
  defp maybe_config(command, config_fun, value), do: config_fun.(command, value)

  defp approval_config(nil), do: nil
  defp approval_config(value), do: ~s(approval_policy="#{format_approval(value)}")

  defp search_config(nil), do: nil
  defp search_config(value), do: ~s(web_search="#{value}")

  defp format_approval(:on_request), do: "on-request"
  defp format_approval(value), do: Atom.to_string(value)
end
