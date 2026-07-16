# HotPotQA subset attribution

`hotpotqa-validation-0-10.jsonl` is a deterministic ten-row materialization
from the HotPotQA `fullwiki` validation split. It was retrieved through the
Hugging Face datasets server at the exact URL recorded in the adjacent
manifest, then normalized into one JSON object per line without changing the
questions, answers, supporting-fact labels, or passage text.

HotPotQA was created by Zhilin Yang, Peng Qi, Saizheng Zhang, Yoshua Bengio,
William W. Cohen, Ruslan Salakhutdinov, and Christopher D. Manning. The dataset
and processed Wikipedia corpus are distributed under the Creative Commons
Attribution-ShareAlike 4.0 International license:

- Project: https://hotpotqa.github.io/
- Source repository: https://github.com/hotpotqa/hotpot
- License: https://creativecommons.org/licenses/by-sa/4.0/
- Paper: https://aclanthology.org/D18-1259/

This subset remains under CC BY-SA 4.0. The repository's MIT license does not
replace or narrow that license for these data files. The adjacent manifest
records the source URL, split, offset, row count, transformation identity, and
SHA-256 digest required for reproduction.
