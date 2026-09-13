defmodule Imp.ACP.Session do
  @moduledoc false

  use GenServer

  require Logger

  defstruct [
    :session_id,
    :program,
    :factory_cleanup,
    :options,
    :metadata,
    :active,
    :history,
    :transcript,
    cleaned?: false
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def prompt(pid, prompt, context), do: GenServer.call(pid, {:prompt, prompt, context})
  def cancel(pid), do: GenServer.call(pid, :cancel, 30_000)
  def close(pid), do: GenServer.call(pid, :close, 30_000)

  @impl true
  def init(opts) do
    options = Keyword.fetch!(opts, :options)
    metadata = Keyword.fetch!(opts, :metadata)

    case Imp.ACP.Options.build_program(options, metadata) do
      {:ok, program, factory_cleanup} ->
        case Imp.ACP.SessionStore.load_history(Keyword.get(opts, :history)) do
          {:ok, history} ->
            {:ok,
             %__MODULE__{
               session_id: Keyword.fetch!(opts, :session_id),
               program: program,
               factory_cleanup: factory_cleanup,
               options: options,
               metadata: metadata,
               history: history,
               transcript: Keyword.get(opts, :transcript, [])
             }}

          {:error, reason} ->
            :ok = Imp.ACP.Options.cleanup(options, program)
            :ok = Imp.ACP.Options.cleanup_factory(factory_cleanup)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prompt, _prompt, _context}, _from, %{active: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :prompt_already_active}, state}
  end

  def handle_call({:prompt, prompt, context}, _from, state) do
    mapping_context = Map.merge(state.metadata, %{history: state.history})

    with {:ok, user_text} <- Imp.ACP.Prompt.text(prompt),
         {:ok, inputs} <-
           Imp.ACP.Options.inputs(state.options, state.program, prompt, mapping_context) do
      owner = self()
      turn_ref = make_ref()

      run_options =
        [event_sink: fn event -> send(owner, {:imp_run_event, turn_ref, event}) end]
        |> authorization_options(state, owner, turn_ref)

      turn_program = %Imp.ACP.TurnProgram{
        program: state.program,
        lifecycle: state.factory_cleanup
      }

      {:ok, run} = Imp.Run.start(turn_program, inputs, run_options)

      active = %{
        run: run,
        agent: context.agent,
        prompt_id: context.prompt_id,
        inputs: inputs,
        user_text: user_text,
        turn_ref: turn_ref,
        pending_result: nil,
        emitted_tool_calls: MapSet.new()
      }

      {:reply, :ok, %{state | active: active}}
    else
      {:error, reason} ->
        :ok = Imp.ACP.Options.after_turn(state.factory_cleanup)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, %{active: nil} = state), do: {:reply, :ok, state}

  def handle_call(
        {:prepare_authorization, turn_ref, request},
        _from,
        %{active: %{turn_ref: turn_ref}} = state
      ) do
    case ensure_pending_tool_call(state, request) do
      {:ok, state, tool_call_id} ->
        spec = %{
          agent: state.active.agent,
          session_id: state.session_id,
          tool_call_id: tool_call_id,
          tool_call: permission_tool_call(state, request, tool_call_id)
        }

        {:reply, {:ok, spec}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prepare_authorization, _turn_ref, _request}, _from, state) do
    {:reply, {:error, :turn_inactive}, state}
  end

  def handle_call(
        {:authorization_allowed, turn_ref, tool_call_id},
        _from,
        %{active: %{turn_ref: turn_ref}} = state
      ) do
    result =
      safe_tool_call_update(state.active.agent, state.session_id, %{
        "toolCallId" => tool_call_id,
        "status" => "in_progress"
      })

    {:reply, result, state}
  end

  def handle_call({:authorization_allowed, _turn_ref, _tool_call_id}, _from, state) do
    {:reply, {:error, :turn_inactive}, state}
  end

  def handle_call(:cancel, _from, state) do
    case Imp.ACP.Options.cancel(state.options, state.program, state.metadata) do
      :ok -> {:reply, :ok, cancel_active(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = state |> cancel_active() |> cleanup()
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({ref, result}, %{active: %{run: %Imp.Run{task: %Task{ref: ref}}}} = state) do
    Process.demonitor(ref, [:flush])
    barrier_ref = make_ref()
    :ok = Imp.Run.barrier(state.active.run, self(), barrier_ref)
    active = %{state.active | pending_result: {barrier_ref, result}}
    {:noreply, %{state | active: active}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active: %{run: %Imp.Run{task: %Task{ref: ref}}}} = state
      ) do
    {:noreply, fail_turn({:task_exit, reason}, state)}
  end

  def handle_info(
        {:imp_run_barrier, barrier_ref},
        %{active: %{pending_result: {barrier_ref, result}}} = state
      ) do
    :ok = Imp.Run.stop(state.active.run)
    {:noreply, complete(result, state)}
  end

  def handle_info(
        {:imp_run_event, turn_ref, event},
        %{active: %{turn_ref: turn_ref}} = state
      ) do
    {:noreply, emit_event(state, event)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> cancel_active() |> cleanup()
    :ok
  end

  defp complete({:ok, %Imp.Prediction{} = prediction}, state) do
    context = Map.merge(state.metadata, %{program: state.program, inputs: state.active.inputs})

    case Imp.ACP.Options.render(state.options, prediction, context) do
      {:ok, text} ->
        history = Imp.ACP.Options.extract_history(prediction, state.history)

        transcript =
          state.transcript ++ [%{"user" => state.active.user_text, "assistant" => text}]

        case Imp.ACP.SessionStore.persist(
               state.options.session_store,
               state.session_id,
               state.metadata,
               history,
               transcript
             ) do
          :ok ->
            state.active.agent
            |> safe_agent_message(state.session_id, text)

            safe_finish(state.active.agent, state.active.prompt_id, "end_turn")

            :ok = Imp.ACP.Options.after_turn(state.factory_cleanup)
            %{state | active: nil, history: history, transcript: transcript}

          {:error, reason} ->
            fail_turn({:session_persistence_failed, reason}, state)
        end

      {:error, reason} ->
        fail_turn(reason, state)
    end
  end

  defp complete({:error, reason}, state), do: fail_turn(reason, state)
  defp complete(other, state), do: fail_turn({:invalid_imp_result, result_shape(other)}, state)

  defp fail_turn(reason, %{active: nil} = state) do
    Logger.debug("ignored failure for inactive Imp ACP turn", reason_shape: result_shape(reason))
    state
  end

  defp fail_turn(reason, state) do
    :ok = Imp.ACP.Options.after_turn(state.factory_cleanup)
    message = failure_message(reason)
    safe_agent_message(state.active.agent, state.session_id, message)

    safe_finish(state.active.agent, state.active.prompt_id, %{
      "stopReason" => "refusal",
      "_meta" => %{"imp_acp" => %{"failure" => failure_detail(reason)}}
    })

    %{state | active: nil}
  end

  defp cancel_active(%{active: nil} = state), do: state

  defp cancel_active(state) do
    _ = Imp.Run.cancel(state.active.run, :acp_cancelled, state.options.cancel_timeout)
    Process.demonitor(state.active.run.task.ref, [:flush])
    :ok = Imp.ACP.Options.after_turn(state.factory_cleanup)
    %{state | active: nil}
  end

  defp authorization_options(
         run_options,
         %{options: %{permission_policy: :unrestricted}},
         _owner,
         _turn_ref
       ),
       do: run_options

  defp authorization_options(run_options, state, owner, turn_ref) do
    authorize = fn request ->
      case Imp.ACP.Options.permission(state.options, request, state.metadata) do
        :allow -> authorize_locally(owner, turn_ref, request)
        :client -> authorize_via_client(owner, turn_ref, request)
        {:deny, _reason} = denied -> denied
      end
    end

    run_options ++
      [authorize: authorize, authorization_timeout: state.options.authorization_timeout]
  end

  # A policy callback is a control-flow decision, not display metadata. Consult
  # it exactly once at the effect boundary, then project that decision into ACP.
  # Preparing the card here also makes ordering honest when authorization races
  # ahead of the asynchronously delivered source event.
  defp authorize_locally(owner, turn_ref, request) do
    with {:ok, spec} <- GenServer.call(owner, {:prepare_authorization, turn_ref, request}),
         :ok <- GenServer.call(owner, {:authorization_allowed, turn_ref, spec.tool_call_id}) do
      :allow
    else
      {:error, reason} -> {:deny, {:local_authorization_unavailable, safe_reason_tag(reason)}}
    end
  end

  defp authorize_via_client(owner, turn_ref, request) do
    with {:ok, spec} <- GenServer.call(owner, {:prepare_authorization, turn_ref, request}),
         decision <- request_client_permission(spec),
         :ok <- mark_authorized_if_allowed(owner, turn_ref, spec.tool_call_id, decision) do
      decision
    else
      {:error, reason} -> {:deny, {:acp_permission_unavailable, safe_reason_tag(reason)}}
    end
  end

  defp request_client_permission(spec) do
    options = [
      %{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"},
      %{
        "optionId" => "allow_always",
        "name" => "Always allow",
        "kind" => "allow_always",
        "description" => "Remember this exact tool for this agent context"
      },
      %{"optionId" => "deny", "name" => "Deny once", "kind" => "reject_once"},
      %{
        "optionId" => "deny_always",
        "name" => "Always deny",
        "kind" => "reject_always",
        "description" => "Block this exact tool for this agent context until revoked"
      }
    ]

    spec.agent
    |> ExMCP.ACP.Agent.request_permission(spec.session_id, spec.tool_call, options,
      timeout: :infinity
    )
    |> permission_decision()
  end

  defp permission_decision({:ok, %{"outcome" => outcome}}), do: permission_outcome(outcome)
  defp permission_decision({:ok, outcome}), do: permission_outcome(outcome)

  defp permission_decision({:error, reason}),
    do: {:deny, {:acp_permission_error, safe_reason_tag(reason)}}

  defp permission_decision(other),
    do: {:deny, {:invalid_acp_permission_response, result_shape(other)}}

  defp permission_outcome(%{"outcome" => "selected", "optionId" => "allow"}),
    do: :allow

  defp permission_outcome(%{"outcome" => "selected", "optionId" => "allow_always"}),
    do: :allow

  defp permission_outcome(%{"outcome" => "selected", "optionId" => "deny"}),
    do: {:deny, :client_denied}

  defp permission_outcome(%{"outcome" => "selected", "optionId" => "deny_always"}),
    do: {:deny, :client_denied}

  defp permission_outcome(%{"outcome" => "cancelled"}),
    do: {:deny, :permission_cancelled}

  defp permission_outcome(%{"outcome" => "selected"}),
    do: {:deny, :invalid_permission_option}

  defp permission_outcome(_outcome),
    do: {:deny, :invalid_permission_outcome}

  defp mark_authorized_if_allowed(owner, turn_ref, tool_call_id, :allow) do
    GenServer.call(owner, {:authorization_allowed, turn_ref, tool_call_id})
  end

  defp mark_authorized_if_allowed(_owner, _turn_ref, _tool_call_id, _decision), do: :ok

  defp ensure_pending_tool_call(state, request) do
    case acp_tool_call_id(request) do
      {:ok, tool_call_id} ->
        if MapSet.member?(state.active.emitted_tool_calls, tool_call_id) do
          {:ok, state, tool_call_id}
        else
          update = permission_tool_call(state, request, tool_call_id)

          case safe_tool_call(state.active.agent, state.session_id, update) do
            :ok -> {:ok, put_emitted_tool_call(state, tool_call_id), tool_call_id}
            {:error, reason} -> {:error, reason, state}
          end
        end

      :error ->
        {:error, :missing_tool_call_identity, state}
    end
  end

  defp permission_tool_call(state, request, tool_call_id) do
    %{
      "toolCallId" => tool_call_id,
      "title" => tool_title(request.tool_name, request.arguments),
      "kind" => tool_kind(state, request.tool_name),
      "status" => "pending",
      "rawInput" => request.arguments,
      "_meta" => %{
        "deepfates.com/imp-acp" => %{"toolName" => to_string(request.tool_name)}
      }
    }
    |> maybe_put_diff(request.tool_name, request.arguments)
  end

  defp maybe_put_diff(tool_call, name, arguments)
       when name in [:write_file, "write_file", :create_file, "create_file"] do
    case {argument(arguments, :path), argument(arguments, :content)} do
      {path, content} when is_binary(path) and is_binary(content) ->
        Map.put(tool_call, "content", [
          %{"type" => "diff", "path" => path, "oldText" => nil, "newText" => content}
        ])

      _missing ->
        tool_call
    end
  end

  defp maybe_put_diff(tool_call, _name, _arguments), do: tool_call

  defp put_emitted_tool_call(state, tool_call_id) do
    active = %{
      state.active
      | emitted_tool_calls: MapSet.put(state.active.emitted_tool_calls, tool_call_id)
    }

    %{state | active: active}
  end

  defp initial_tool_status(%{options: %{permission_policy: :unrestricted}}),
    do: "in_progress"

  defp initial_tool_status(_state), do: "pending"

  defp emit_event(state, %Imp.Run.Event{kind: :reasoning, reasoning: reasoning})
       when is_binary(reasoning) and reasoning != "" do
    _ = safe_agent_thought(state.active.agent, state.session_id, reasoning)
    state
  end

  defp emit_event(state, %Imp.Run.Event{kind: :tool_call, tool_name: name})
       when name in [:submit, "submit"],
       do: state

  defp emit_event(state, %Imp.Run.Event{kind: :tool_call} = event) do
    case acp_tool_call_id(event) do
      {:ok, tool_call_id} ->
        if MapSet.member?(state.active.emitted_tool_calls, tool_call_id) do
          state
        else
          case safe_tool_call(state.active.agent, state.session_id, %{
                 "toolCallId" => tool_call_id,
                 "title" => tool_title(event.tool_name, event.input),
                 "kind" => tool_kind(state, event.tool_name),
                 "status" => initial_tool_status(state),
                 "rawInput" => tool_input(event.input)
               }) do
            :ok -> put_emitted_tool_call(state, tool_call_id)
            {:error, _reason} -> state
          end
        end

      :error ->
        Logger.warning("ignored Imp tool call without a stable run-scoped identity")
        state
    end
  end

  defp emit_event(state, %Imp.Run.Event{kind: :tool_result, tool_name: name})
       when name in [:submit, "submit"],
       do: state

  defp emit_event(state, %Imp.Run.Event{kind: :tool_result} = event) do
    failed? = not is_nil(event.error)
    value = if(failed?, do: event.error, else: event.output)

    case acp_tool_call_id(event) do
      {:ok, tool_call_id} ->
        state = ensure_result_tool_call(state, event, tool_call_id)

        _ =
          safe_tool_call_update(state.active.agent, state.session_id, %{
            "toolCallId" => tool_call_id,
            "status" => if(failed?, do: "failed", else: "completed"),
            "content" => [
              %{
                "type" => "content",
                "content" => %{"type" => "text", "text" => safe_event_text(value)}
              }
            ]
          })

        state

      :error ->
        Logger.warning("ignored Imp tool result without a stable run-scoped identity")
        state
    end
  end

  defp emit_event(state, %Imp.Run.Event{}), do: state

  # Validation can reject a model-selected call before Imp emits a start event.
  # ACP still requires a correlated tool_call before its terminal update; this
  # card describes the observed local attempt and never implies authorization or
  # an external effect occurred.
  defp ensure_result_tool_call(state, event, tool_call_id) do
    if MapSet.member?(state.active.emitted_tool_calls, tool_call_id) do
      state
    else
      case safe_tool_call(state.active.agent, state.session_id, %{
             "toolCallId" => tool_call_id,
             "title" => tool_title(event.tool_name, event.input),
             "kind" => tool_kind(state, event.tool_name),
             "status" => "in_progress",
             "rawInput" => tool_input(event.input)
           }) do
        :ok -> put_emitted_tool_call(state, tool_call_id)
        {:error, _reason} -> state
      end
    end
  end

  # Three sources, most specific first: the kind the host declared by name, the
  # kind derived from the MCP annotations this session's servers published, and
  # finally the built-in guess for Imp's own workspace tools.
  defp tool_kind(%{options: %{tool_kinds: kinds}} = state, name) do
    name = to_string(name)

    Map.get(kinds, name) ||
      Map.get(Imp.ACP.Options.factory_tool_kinds(state.factory_cleanup), name) ||
      default_tool_kind(name)
  end

  defp default_tool_kind(name) when name in [:list_files, "list_files", :read_file, "read_file"],
    do: "read"

  defp default_tool_kind(name) when name in [:search_text, "search_text"], do: "search"

  defp default_tool_kind(name)
       when name in [
              :create_file,
              "create_file",
              :replace_text,
              "replace_text",
              :write_file,
              "write_file"
            ],
       do: "edit"

  defp default_tool_kind(name) when name in [:run_command, "run_command"], do: "execute"
  defp default_tool_kind(_name), do: "other"

  defp tool_title(name, arguments) when name in [:read_file, "read_file"],
    do: "Read #{argument(arguments, :path) || "file"}"

  defp tool_title(name, arguments) when name in [:list_files, "list_files"],
    do: "List #{argument(arguments, :path) || "."}"

  defp tool_title(name, arguments) when name in [:search_text, "search_text"],
    do: "Search for #{argument(arguments, :query) || "text"}"

  defp tool_title(name, arguments) when name in [:create_file, "create_file"],
    do: "Create #{argument(arguments, :path) || "file"}"

  defp tool_title(name, arguments) when name in [:write_file, "write_file"],
    do: "Write #{argument(arguments, :path) || "file"}"

  defp tool_title(name, arguments) when name in [:replace_text, "replace_text"],
    do: "Edit #{argument(arguments, :path) || "file"}"

  defp tool_title(name, arguments) when name in [:run_command, "run_command"] do
    command = argument(arguments, :command) || "command"
    args = argument(arguments, :args) || []
    Enum.join([command | Enum.take(args, 8)], " ")
  end

  defp tool_title(name, _arguments), do: "Run #{name}"

  defp argument(arguments, key) when is_map(arguments),
    do: Map.get(arguments, key, Map.get(arguments, Atom.to_string(key)))

  defp argument(_arguments, _key), do: nil

  defp tool_input(input) when is_map(input), do: input
  defp tool_input(input), do: %{"value" => safe_event_text(input)}

  # Imp source IDs correlate one call and result within a program execution.
  # ACP requires tool-call IDs to remain unique for the complete session, so the
  # adapter widens their scope without replacing the source-owned identity.
  defp acp_tool_call_id(%Imp.Run.Event{run_id: run_id, tool_call_id: source_id})
       when is_binary(run_id) and run_id != "" and is_binary(source_id) and source_id != "" do
    {:ok, run_id <> ":" <> source_id}
  end

  defp acp_tool_call_id(%Imp.Run.Event{}), do: :error

  defp acp_tool_call_id(%Imp.Execution.Authorization{
         run_id: run_id,
         tool_call_id: source_id
       })
       when is_binary(run_id) and run_id != "" and is_binary(source_id) and source_id != "" do
    {:ok, run_id <> ":" <> source_id}
  end

  defp acp_tool_call_id(%Imp.Execution.Authorization{}), do: :error

  defp cleanup(%{cleaned?: true} = state), do: state

  defp cleanup(state) do
    :ok = Imp.ACP.Options.cleanup(state.options, state.program)
    :ok = Imp.ACP.Options.cleanup_factory(state.factory_cleanup)
    %{state | cleaned?: true}
  end

  defp safe_agent_message(_agent, _session_id, ""), do: :ok

  defp safe_agent_message(agent, session_id, text) do
    ExMCP.ACP.Agent.agent_message(agent, session_id, text)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp safe_agent_thought(agent, session_id, text) do
    ExMCP.ACP.Agent.agent_thought(agent, session_id, text)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp safe_tool_call(agent, session_id, update) do
    ExMCP.ACP.Agent.tool_call(agent, session_id, update)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp safe_tool_call_update(agent, session_id, update) do
    ExMCP.ACP.Agent.tool_call_update(agent, session_id, update)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp safe_finish(agent, prompt_id, reason) do
    ExMCP.ACP.Agent.finish_prompt(agent, prompt_id, reason)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  # A host that returned a JSON-RPC error triple already wrote the sentence its
  # user needs to read, usually naming the thing to fix. Replacing it with a
  # generic apology throws away the only actionable part of the failure.
  defp failure_message({code, message, _data})
       when is_integer(code) and is_binary(message),
       do: message

  defp failure_message(reason) do
    if timeout_failure?(reason) do
      "The model took too long to finish this request."
    else
      "I couldn't finish this request."
    end
  end

  defp failure_detail({code, _message, data}) when is_integer(code) do
    reason = if is_map(data), do: Map.get(data, "reason"), else: nil
    %{"kind" => to_string(reason || "host_refused"), "category" => "refusal"}
  end

  defp failure_detail(reason) do
    %{
      "kind" => reason |> safe_reason_tag() |> to_string(),
      "category" => if(timeout_failure?(reason), do: "timeout", else: "program_error")
    }
  end

  defp timeout_failure?(reason) when reason in [:timeout, :deadline_exceeded], do: true

  defp timeout_failure?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)
    String.contains?(normalized, "timeout") or String.contains?(normalized, "timed out")
  end

  defp timeout_failure?(%{reason: reason}), do: timeout_failure?(reason)
  defp timeout_failure?(%{"reason" => reason}), do: timeout_failure?(reason)

  defp timeout_failure?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&timeout_failure?/1)
  end

  defp timeout_failure?(reason) when is_list(reason), do: Enum.any?(reason, &timeout_failure?/1)
  defp timeout_failure?(_reason), do: false

  defp safe_reason_tag(reason) when is_atom(reason), do: reason

  defp safe_reason_tag(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_reason_tag(%_{} = error), do: error.__struct__
  defp safe_reason_tag(_reason), do: :unknown

  defp safe_event_text(value) when is_binary(value), do: value
  defp safe_event_text(value), do: inspect(value, limit: 30, printable_limit: 2_000)

  defp result_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp result_shape(value) when is_map(value), do: :map
  defp result_shape(value) when is_list(value), do: :list
  defp result_shape(value) when is_atom(value), do: :atom
  defp result_shape(_value), do: :other
end
