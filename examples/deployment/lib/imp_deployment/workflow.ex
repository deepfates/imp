defmodule ImpDeployment.Workflow do
  @moduledoc """
  Provider-free support-routing workflow used by the deployment walkthrough.

  Its program is a genuine typed two-predictor pipeline: stage one produces an
  `analysis` value, and stage two consumes that value with the original ticket
  to produce validated opaque team and urgency outputs.

  The deterministic LM makes lifecycle behavior reproducible. Its planted
  rules are a teaching fixture, not evidence that few-shot compilation improves
  a real model or an unseen task.
  """

  def program, do: ImpDeployment.SupportPipeline.new()

  def metric(example, prediction) do
    Imp.get(example, :team) == Imp.get(prediction, :team) and
      Imp.get(example, :urgency) == Imp.get(prediction, :urgency)
  end

  def trainset do
    rows([
      {"Duplicate invoice charge", "atlas", "normal"},
      {"API outage blocks checkout", "harbor", "high"},
      {"Password reset is blocked", "beacon", "high"},
      {"How do I export a report?", "quill", "normal"}
    ])
  end

  def selection_set do
    rows([
      {"Refund the annual invoice", "atlas", "normal"},
      {"Dashboard latency is spiking", "harbor", "high"},
      {"An old account can still sign in", "beacon", "high"},
      {"Where are the import docs?", "quill", "normal"}
    ])
  end

  def testset do
    rows([
      {"Please explain this subscription charge", "atlas", "normal"},
      {"The API is down for every customer", "harbor", "high"},
      {"A leaked password still works", "beacon", "high"},
      {"Can I add dark mode?", "quill", "normal"}
    ])
  end

  def compile(program) do
    Imp.optimize!(
      program,
      Imp.Optimizer.LabeledFewShot.new(k: 4, sample: false),
      trainset()
    )
  end

  def evaluate(program, rows, lm \\ static_lm()) do
    Imp.context([lm: lm], fn ->
      Imp.evaluate(program, rows, &metric/2, max_concurrency: 4)
    end)
  end

  def selected_parameters(program) do
    program
    |> Imp.ProgramParameters.parameters()
    |> Enum.map(&Imp.Optimizer.Parameter.dump/1)
  end

  def optimizer_artifact(program) do
    case Imp.Optimizer.Report.fetch(program) do
      nil ->
        program
        |> Imp.Optimizer.Artifact.parameter_candidate("deployment-support-pipeline-baseline")
        |> Imp.Optimizer.Artifact.new([],
          provenance: %{workflow: "provider-free-otp-capstone", selection: "baseline"}
        )

      _report ->
        Imp.Optimizer.Artifact.from_optimized_program(program,
          artifact_id: "deployment-support-pipeline-selected",
          provenance: %{workflow: "provider-free-otp-capstone"}
        )
    end
  end

  def static_lm do
    Imp.LM.Static.new(handler: &static_response/2)
  end

  defp static_response(messages, _opts) do
    query =
      messages
      |> Enum.filter(&(Map.get(&1, :role) in [:user, "user"]))
      |> List.last()
      |> Map.fetch!(:content)

    cond do
      String.contains?(query, "IMP_DEMO_HANG") ->
        Process.sleep(:infinity)

      String.contains?(query, "IMP_DEMO_CRASH") ->
        Process.exit(self(), :kill)

      routing_stage?(messages) and
          Enum.any?(messages, &(Map.get(&1, :role) in [:assistant, "assistant"])) ->
        classified_response(query)

      routing_stage?(messages) ->
        %{team: "atlas", urgency: "normal"}

      Enum.any?(messages, &(Map.get(&1, :role) in [:assistant, "assistant"])) ->
        %{analysis: analysis_for(query)}

      true ->
        %{analysis: "No demonstrated routing convention is installed."}
    end
  end

  defp classified_response(query) do
    query = String.downcase(query)

    team =
      cond do
        String.contains?(query, "billing signal") -> "atlas"
        String.contains?(query, "service health signal") -> "harbor"
        String.contains?(query, "account security signal") -> "beacon"
        true -> "quill"
      end

    urgency = if String.contains?(query, "urgency high"), do: "high", else: "normal"

    %{team: team, urgency: urgency}
  end

  defp analysis_for(query) do
    query = String.downcase(query)

    signal =
      cond do
        contains_any?(query, ["invoice", "refund", "charge", "subscription"]) ->
          "billing signal"

        contains_any?(query, ["outage", "latency", "api is down", "checkout"]) ->
          "service health signal"

        contains_any?(query, ["password", "account", "sign in"]) ->
          "account security signal"

        true ->
          "product guidance signal"
      end

    urgency =
      if contains_any?(query, ["blocked", "outage", "spiking", "still", "down", "leaked"]),
        do: "high",
        else: "normal"

    "#{signal}; urgency #{urgency}"
  end

  defp routing_stage?(messages) do
    Enum.any?(messages, fn message -> String.contains?(message.content, "`team`") end)
  end

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp rows(rows) do
    Enum.map(rows, fn {ticket, team, urgency} ->
      Imp.example(
        ticket: ticket,
        analysis: analysis_for(ticket),
        team: team,
        urgency: urgency
      )
      |> Imp.with_inputs(:ticket)
    end)
  end
end
