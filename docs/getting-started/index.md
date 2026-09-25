# Program, don't prompt

Imp is a way to build with language models in Elixir by writing programs
instead of prompt strings.

We describe each task as named, typed inputs and outputs. Imp writes the
prompt, calls the model, and checks the reply against that description, so
the rest of our code gets a value it can trust. Programs are ordinary Elixir
values: we can test them without a model, score them on examples, let an
optimizer improve them, save them without credentials, and run them under
supervision in an application.

The model is used where judgment is needed. Everything around it stays plain
Elixir.

## What we'll build

One program, from its first call to running in an application: a router for
support tickets. Our company sends tickets to four squads with internal names:

- **atlas** owns money: charges, refunds, invoices, plans.
- **harbor** owns the platform: outages, errors, latency, including technical
  failures in payments and email delivery.
- **beacon** owns identity and trust: accounts, credentials, sessions, data
  exposure.
- **quill** owns the product: feature requests, how-to questions, docs.

No model knows these names. That makes the task small enough to follow and
real enough to need everything Imp offers. Imp ships sixty labeled tickets for
it, which we'll use to measure and improve the router.

## What we'll learn

1. [Setting up](setting-up.md): install Imp and connect a model.
2. [Your first program](first-program.md): a signature, a prediction, and the
   prompt Imp wrote for us.
3. [Expanding signatures](expanding-signatures.md): types, enums,
   descriptions, and the structured form.
4. [Changing the module](changing-the-module.md): chain of thought with the same
   signature.
5. [Testing without a provider](testing-without-a-provider.md): a scripted
   model for fast, free tests.
6. [Tools and agents](tools-and-agents.md): let the model look things up.
7. [Composing programs](composing-programs.md): two stages in one module.
8. [Measuring](measuring.md): examples, a metric, and a baseline.
9. [Improving](improving.md): an optimizer, the score on held-out tickets, and
   what changed.
10. [Saving and loading](save-and-load.md): keep the improved program, never
    the key.
11. [Running it in your application](running-in-your-application.md):
    supervision, timeouts, and bounded concurrency.
12. [Where to go next](where-to-go-next.md).

Each page builds on the one before, and every output shown came from running
the code on it.

---

**Next:** [Setting up →](setting-up.md)
