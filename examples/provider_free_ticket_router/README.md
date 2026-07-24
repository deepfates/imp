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
fixture built to expose the lifecycle; this result is not a claim that
`LabeledFewShot` will improve a real model or your dataset. Use a real held-out
set and metric to establish that claim for your program.

When this example is exercised by Imp's package gate, it is copied out of the
package and compiled as an ordinary consumer against the unpacked artifact with
Hex forced offline.
