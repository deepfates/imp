# Saving and loading

The improved router is worth keeping. `Imp.save!/2` writes a program to a JSON
file, and `Imp.read!/1` reads it back:

```elixir
path = Path.join(System.tmp_dir!(), "ticket_router.json")
:ok = Imp.save!(improved, path)

saved = File.read!(path)
{saved =~ "gpt-5.4-mini", saved =~ System.fetch_env!("OPENAI_API_KEY")}
#=> {true, false}
```

The file holds the program: its signature and instruction, its demos, its
adapter, and the name of the model it was built with. It never holds the key.
Credentials belong to the process that runs the program, not to the program.
The file also carries a checksum, and `Imp.read!/1` refuses a file that has
been altered or damaged.

So we bind a model when we load:

```elixir
loaded = path |> Imp.read!() |> Imp.with_lm(lm)

Imp.evaluate(loaded, testset, metric, num_threads: 8).score
#=> 0.75
```

The loaded router scores what `improved` scored. It sends exactly the same
messages, so all twenty calls were answered from the cache, in a few
milliseconds.

`Imp.with_lm/2` can bind a different model, too: the saved demos and
instruction stay, and we can measure how they do on the new one before we
switch.

## Commit it

The saved file is plain JSON. When an optimizer run produces a better program,
the change arrives as a diff, and review sees exactly which instructions and
examples moved. Keep the metric and data that justified it alongside.

`Imp.save!/2` stores Imp's own program types, like the router. A program we
defined ourselves, such as `TicketTriage`, is our code: it lives in our
release, and only what an optimizer learned for it needs saving.
`Imp.Optimizer.Artifact` saves those learned parameters and applies them to a
freshly built program; the next page's example application does exactly that.
[Saving and artifacts](../diving-deeper/saving-and-artifacts.md) covers both.

---

**Next:** [Running it in your application →](running-in-your-application.md)
