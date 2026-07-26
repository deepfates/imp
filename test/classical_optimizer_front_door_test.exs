defmodule Imp.ClassicalOptimizerFrontDoorTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{Artifact, BootstrapFewShot, RandomSearch, Report}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-classical-front-door-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "RandomSearch routes source-defined compile options through Imp.optimize! and persists teacher demos",
       %{path: path} do
    owner = self()
    student = program("student")
    teacher = teacher_program(owner, "teacher")
    trainset = [example("bootstrap", "teacher")]
    validation = [example("selection", "student")]

    optimized =
      student
      |> Imp.optimize!(
        RandomSearch.new(&exact_answer/2,
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
      RandomSearch.new(&exact_answer/2,
        num_candidate_programs: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    assert_raise ArgumentError, ~r/unknown options.*techer/, fn ->
      RandomSearch.compile(random, student, trainset, validation,
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

    assert Enum.map(applied.demos, &Imp.Example.to_map/1) ==
             Enum.map(optimized.demos, &Imp.Example.to_map/1)

    assert applied.lm == fresh.lm
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
end
