%{
  configs: [
    %{
      name: "default",
      checks: %{
        # These are narrow exceptions to Credo's default warning checks. The
        # files remain covered by every other default check.
        extra: [
          # BEAM numeric values are finite, but these protocol boundaries keep
          # the explicit self-comparison used by their cross-language guards.
          {Credo.Check.Warning.OperationOnSameValues,
           files: %{
             excluded: [
               "lib/imp/clients/trl_protocol.ex",
               "lib/imp/clients/trl_trainer.ex",
               "lib/imp/optimizer/grpo.ex"
             ]
           }},
          # These rescue paths intentionally translate or reclassify the
          # boundary exception instead of preserving its original identity.
          {Credo.Check.Warning.RaiseInsideRescue,
           files: %{
             excluded: [
               "lib/imp/optimize/anything/structured_candidate.ex",
               "lib/imp/optimize/anything/structured_strategy.ex",
               "lib/imp/optimizer/mipro_v2.ex"
             ]
           }},
          # GEPA's public constructor mirrors a wide upstream option surface;
          # nesting it would break persisted/public optimizer state.
          {Credo.Check.Warning.StructFieldAmount,
           files: %{excluded: ["lib/imp/optimizer/gepa.ex"]}}
        ]
      }
    }
  ]
}
