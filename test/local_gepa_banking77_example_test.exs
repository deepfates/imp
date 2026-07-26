defmodule Imp.LocalGEPABanking77ExampleTest do
  use ExUnit.Case, async: false

  setup_all do
    previous = System.get_env("IMP_GEPA_DEFINE_ONLY")
    System.put_env("IMP_GEPA_DEFINE_ONLY", "1")
    Code.require_file("examples/local_gepa_banking77/run.exs", File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_GEPA_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_GEPA_DEFINE_ONLY")
    end)

    :ok
  end

  test "ordinary two-predictor program uses distinct runtimes and hands evidence to classifier" do
    owner = self()

    analyzer =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:analyzer, messages})
          %{evidence: "fee evidence from analyzer"}
        end
      )

    classifier =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:classifier, messages})
          rendered = Enum.map_join(messages, "\n", & &1.content)
          if rendered =~ "fee evidence from analyzer", do: %{route: "R17"}, else: %{route: "R93"}
        end
      )

    router = apply(LocalGEPABanking77.Router, :new, [analyzer, classifier])

    assert {:ok, prediction} = Imp.call(router, %{utterance: "Why was I charged a card fee?"})
    assert Imp.Prediction.get(prediction, :route) == "R17"
    assert_receive {:analyzer, analyzer_messages}
    assert_receive {:classifier, classifier_messages}

    assert Imp.Adapter.Instructions.rendered_objective?(
             router.analyze_intent.signature.instructions,
             analyzer_messages
           )

    assert Imp.Adapter.Instructions.rendered_objective?(
             router.classify_route.signature.instructions,
             classifier_messages
           )

    assert Enum.any?(
             classifier_messages,
             &String.contains?(&1.content, "fee evidence from analyzer")
           )
  end
end
