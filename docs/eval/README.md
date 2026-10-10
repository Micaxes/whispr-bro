# `docs/eval/leaderboard.jsonl`

Append-only, one JSON object per line, one line per formatter column per run
(plan §5, §6.1). This file holds **seeds-only** rows — the public, synthetic
fixture set — never his dictations; the personal leaderboard lives outside
the repo at `$WHISPR_EVAL_HOME/leaderboard.jsonl` (default
`~/OS/dev/whispr-bro-eval/leaderboard.jsonl`). See
[`docs/eval-benchmark.md`](../eval-benchmark.md) for the full row shape, the
scoring formulas, and how to read a report.

It is written by `scripts/bench-eval.sh` — never by hand. The script computes
`--git-sha` from the working tree and appends here automatically whenever the
run scores the built-in seeds (no fixtures path in the invocation); a run
against any other fixtures file never touches this path (`whispr-bench eval`
itself refuses a `--append` inside the repo tree unless the fixture set is
the seeds — belt and braces, plan §3.3).

A row, shape (the leaderboard object minus `rows`; the bench writes it
with sorted keys and no `null`s — a nil field is omitted):

```json
{"date":"2026-09-14T18:02:00Z","git_sha":"36ff03b","dirty":false,"label":"baseline",
 "formatter":"llama","model_key":"qwen2.5-1.5b","model_sha256":"…","prompt_sha256":"…","level":"fixture",
 "fixtures":{"name":"seeds","sha256":"…","n":81,"rated_n":81,"draft_n":0},
 "scoring_version":4,"run_key":"3f9a1c2b7e04",
 "scores":{"F":88.4,"Fi":95.0,"M":71.2,"C":79.1},
 "verdicts":{"PASS":58,"PUNCT":9,"MISSED":4,"REWORDED":3,"OVER_EDIT_HEDGE":4,"OVER_EDIT_FACT":1,"NEGATED":0,"INVENTED":1,"ANSWERED":1,"UNRATED":0},
 "gate":{"status":"FAIL","answered":1,"invented":1,"negated":0,"over_edit_fact":1,"controls":49,"controls_unchanged":49,"controls_unchanged_pct":100,"latency_over_budget":false},
 "fallbacks":{"fastPath":12,"rawMode":0,"timedOut":1,"rejected":0,"unavailable":0,"requestFailed":0},
 "latency_ms":{"n_llm":62,"p50":417,"p90":1650,"p99":2900,"p99_le60":1650,"max":3063,"budget":700,"over_budget":29,"ms_per_word":18.4,"reprime_ms":[900,1100],"by_length":{"<=15":{"n":20,"p50":210,"p99":600}}},
 "calibrated":false,
 "machine":{"model":"Mac14,12","os":"26.5.1"}}
```

`model_sha256` is the GGUF digest for llama, `foundation@<os build>` for
the Apple model, `rules` for the rules column and `shipped@<first 12 hex of
fixtures.sha256>` for the shipped column (the observed outputs are part of
the fixture set, so its hash already identifies what the binary produced).
`latency_ms.n_llm` counts the rows in the percentiles — the model-path rows
minus the re-primes listed in `reprime_ms` — so `over_budget / n_llm` is the
fraction the terminal prints; `p50` … `max` are absent when no timed row
exists.

Read it with `whispr-bench leaderboard docs/eval/leaderboard.jsonl [--top N]`
or diff two `run_key`s with `--diff`; a diff across different `fixtures.sha256`
or `scoring_version` is refused, not silently misleading.
