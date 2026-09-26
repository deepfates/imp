defmodule Imp.ClassicalOptimizerFrontDoorTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{Artifact, BootstrapFewShot, BootstrapFewShotWithRandomSearch, Report}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-classical-front-door-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "BootstrapFewShotWithRandomSearch routes source-defined compile options through Imp.optimize! and persists teacher demos",
       %{path: path} do
    owner = self()
    student = program("student")
    teacher = teacher_program(owner, "teacher")
    trainset = [example("bootstrap", "teacher")]
    validation = [example("selection", "student")]

    optimized =
      student
      |> Imp.optimize!(
        BootstrapFewShotWithRandomSearch.new(&exact_answer/2,
          num_candidate_programs: 1,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0,
          max_rounds: 1,
          num_threads: 1
        ),
        trainset,
        validation,
        teacher: teacher,
        restrict: [-1],
        labeled_sample: false
      )

    assert_receive {:teacher_called, "bootstrap"}
    refute_receive {:teacher_called, "selection"}
    assert Report.fetch(optimized).metadata.candidate_seeds == [-1]
    assert [demo] = optimized.demos

    assert Imp.Example.to_map(demo) == %{
             question: "bootstrap",
             answer: "teacher",
             augmented: true
           }

    assert_persisted_demo(optimized, student, path)
  end

  test "BootstrapFewShot routes its teacher through the trainset-only Imp.optimize! front door",
       %{path: path} do
    owner = self()
    student = program("student")
    teacher = teacher_program(owner, "teacher")

    optimized =
      student
      |> Imp.optimize!(
        BootstrapFewShot.new(&exact_answer/2,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0,
          max_rounds: 1
        ),
        [example("bootstrap", "teacher")],
        teacher: teacher
      )

    assert_receive {:teacher_called, "bootstrap"}
    assert [demo] = optimized.demos

    assert Imp.Example.to_map(demo) == %{
             question: "bootstrap",
             answer: "teacher",
             augmented: true
           }

    assert_persisted_demo(optimized, student, path)
  end

  test "classical compile options reject unknown and malformed values before teacher calls" do
    owner = self()
    student = program("student")
    teacher = teacher_program(owner, "teacher")
    trainset = [example("bootstrap", "teacher")]
    validation = [example("selection", "student")]

    random =
      BootstrapFewShotWithRandomSearch.new(&exact_answer/2,
        num_candidate_programs: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    assert_raise ArgumentError, ~r/unknown options.*techer/, fn ->
      BootstrapFewShotWithRandomSearch.compile(random, student, trainset, validation,
        teacher: teacher,
        techer: teacher
      )
    end

    assert_raise ArgumentError, ~r/:restrict option/, fn ->
      Imp.optimize!(student, random, trainset, validation,
        teacher: teacher,
        restrict: [:bootstrap]
      )
    end

    bootstrap =
      BootstrapFewShot.new(&exact_answer/2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    assert_raise ArgumentError, ~r/unknown options.*restrict/, fn ->
      BootstrapFewShot.compile(bootstrap, student, trainset,
        teacher: teacher,
        restrict: [-1]
      )
    end

    refute_receive {:teacher_called, _question}
  end

  defp assert_persisted_demo(optimized, fresh, path) do
    artifact = Artifact.from_optimized_program(optimized)
    :ok = Artifact.write!(artifact, path)
    applied = path |> Artifact.read!() |> Artifact.apply(fresh)

    # A demo field the signature does not declare (BootstrapFewShot's
    # `augmented` marker) is read back under the string key the artifact
    # stores; keys are compared by text.
    assert Enum.map(applied.demos, &text_keys/1) == Enum.map(optimized.demos, &text_keys/1)

    assert applied.lm == fresh.lm
    applied_report = Report.fetch(applied)
    optimized_report = Report.fetch(optimized)
    assert applied_report.optimizer == optimized_report.optimizer
    assert applied_report.best_score == optimized_report.best_score
    assert applied_report.candidate_count == optimized_report.candidate_count
    assert_fresh_os_artifact(path, Report.fetch(optimized))
  end

  defp assert_fresh_os_artifact(path, expected_report) do
    expression = """
    {:ok, _} = Application.ensure_all_started(:imp)

    fresh =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "fresh"} end)
      )

    applied =
      System.argv()
      |> hd()
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(fresh)

    report = Imp.Optimizer.Report.fetch(applied)

    unless report && to_string(report.optimizer) == #{inspect(to_string(expected_report.optimizer))} and
             report.best_score == #{inspect(expected_report.best_score)} and
             report.candidate_count == #{inspect(expected_report.candidate_count)} and
             length(applied.demos) == 1 and applied.lm == fresh.lm do
      raise "fresh artifact lost its report, parameters, or runtime binding: \#{inspect({report, applied})}"
    end
    """

    args =
      "_build/test/lib/*/ebin"
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])
      |> Kernel.++(["-e", expression, path])

    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp program(answer) do
    Imp.predict("question -> answer",
      lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: answer} end)
    )
  end

  defp teacher_program(owner, answer) do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)

            [question] =
              ~r/\[\[ ## question ## \]\]\s*([^\n]+)/
              |> Regex.scan(prompt, capture: :all_but_first)
              |> List.last()

            send(owner, {:teacher_called, String.trim(question)})
            %{answer: answer}
          end
        )
    )
  end

  defp example(question, answer),
    do: Imp.example(question: question, answer: answer) |> Imp.with_inputs(:question)

  defp exact_answer(example, prediction),
    do: Imp.Example.get(example, :answer) == Imp.Prediction.get(prediction, :answer)

  defp text_keys(example),
    do: Map.new(Imp.Example.to_map(example), fn {key, value} -> {to_string(key), value} end)
end
