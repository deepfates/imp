# Identity Research Authorities

Last policy review: 2026-07-13.

This file records operating constraints for reproducible checks. It is not a
clearance opinion, and an absent search result is never treated as availability.

## Package And Repository Checks

- [Hex publishing documentation](https://hex.pm/docs/publish) and the public
  package endpoint at `https://hex.pm/api/packages/{name}` are the Hex package
  authorities used for exact observations.
- [npm registry documentation](https://docs.npmjs.com/using-npm/registry.html/)
  identifies `https://registry.npmjs.org` as the default public registry. The
  [npm crawler policy](https://docs.npmjs.com/policies/crawlers/) is treated as
  a conservative one-request-per-second ceiling for this audit.
- [PyPI API policy](https://docs.pypi.org/api/) requests an identifying
  `User-Agent`, serial access over a longer period, and restraint against
  thousands of requests in minutes. The JSON endpoint is
  `https://pypi.org/pypi/{project}/json`.
- [crates.io data-access policy](https://crates.io/data-access) requires an
  identifying `User-Agent`, limits API access to one request per second, and
  prefers the index or data dump for bulk analysis.
- [GitHub REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
  govern later repository checks. Search results are repository observations,
  not proof that a name is free of product or company confusion.

The package checker therefore runs sequentially, defaults to at least one
second between requests, records timestamped response evidence, resumes without
repeating completed tuples, and leaves failures or rate limits unverified.

## Marks And Language

- [WIPO Global Brand Database FAQ](https://www.wipo.int/en/web/global-brand-database/faqs_branddb)
  prohibits robot or automatic queries and warns that a missing result does not
  establish availability. WIPO and relevant national databases are reviewed
  manually only for decision-front candidates.
- [USPTO trademark search](https://www.uspto.gov/trademarks/search) is likewise
  a manual decision-front check. No repository report calls it legal clearance.
- [Unicode Technical Standard #39](https://www.unicode.org/reports/tr39/)
  supplies confusable detection. Its skeleton algorithm is a warning mechanism,
  not candidate normalization or a reason to erase a spelling.

Living-language, Indigenous, sacred, and culturally situated forms remain
unverified hypotheses until relevant language and community reviewers assess
meaning, pronunciation, transliteration, context, and use.
