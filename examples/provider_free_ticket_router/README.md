# Provider-free ticket router

This is the smallest complete Imp consumer path: declare a typed LM program,
measure a baseline on held-out examples, compile the program with a deterministic
optimizer, and measure it again. It uses `Imp.LM.Static`, so it needs no API key,
makes no provider call, and spends no money.

From this directory in an Imp source checkout or unpacked package:

```sh
mix deps.get
mix run run.exs
```

The program reports `25% -> 100%` and shows that the compiled program retains
four reviewable demonstrations and the exact
`enum[atlas,harbor,beacon,quill]` output type. The deterministic LM is a teaching
fixture for seeing exactly how compilation changes a program. Replace it with
your provider, data, and metric to measure the behavior you care about.
