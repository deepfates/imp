# Tutorial support tickets

`support_tickets.json` is sixty short support tickets, each labeled with one of
four invented squad names (atlas, harbor, beacon, quill), split twenty/twenty/
twenty into train, dev and test. SHA-256 of the file:
`7ea5ae7ad724dc4311cf954bafeb48a4b7b284b619c33bc00b30d37ad6df6f87`.

The tickets were written for this repository. They are not drawn from any
external dataset, and no real customer, company or person appears in them. The
squad names encode a routing convention that no model can guess, which is the
point of [the getting-started guide](../../docs/getting-started/index.md): it makes the
gap between what a model can read and what an organization means measurable.

**License: MIT, the same as the rest of this repository.** The file ships in the
Hex package; you may copy it, change it, and replace it with your own tickets.

Because we wrote them, they carry the usual risks of an author-written set: the
labels reflect one person's idea of the convention, the tickets are short and
unambiguous compared to real ones, and twenty held-out rows is a coarse
instrument. Results measured on this file say something about Imp's optimizer
plumbing and nothing about your ticket queue.
