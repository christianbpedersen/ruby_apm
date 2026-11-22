# RubyAPM ingest protocol, v1

Agents POST one document per flush (default every 10 s) to:

```
POST /api/v1/ingest
Authorization: Bearer <app api key>
Content-Type: application/msgpack      (or application/json)
Content-Encoding: gzip                 (optional)
```

Responses: `202` accepted (body lists rows written per table), `401` unknown
key, `413` body over 20 MB, `422` malformed document. Agents retry on network
errors, 5xx and 429, and drop the payload on other 4xx.

The server only adds: sending the same minute twice (from several processes,
or a retry after a timeout) sums into the same rows.

## Document

| Key | Type | |
|---|---|---|
| `v` | int | always `1` |
| `agent` | string | agent version |
| `app` | string | app name (used to auto-register in development) |
| `env`, `host`, `pid` | string, string, int | identify the process |
| `sent_at` | float | epoch seconds |
| `rails`, `ruby` | string | versions, informational |
| `apdex_t` | float | ms; the T the agent scored Apdex with |
| `revision` | string? | deployed code revision; first sighting = deployment |
| `booted_at` | float | epoch seconds the process started (deployment time) |
| `buckets` | array | per-minute aggregates, below |
| `traces` | array | slow/errored transaction traces, below |
| `slow_queries` | array | individual slow SQL executions, below |
| `runtime` | object? | process metrics since the previous flush, below |

Durations are milliseconds (floats). Histograms are sparse maps
`{bucket_index => count}` where bucket `i` holds durations in
`(1.25^(i-1), 1.25^i]` ms, bucket 0 is `<= 1 ms`, and there are 56 buckets.

### Bucket

```
{ "ts": <minute, epoch seconds, divisible by 60>,
  "transactions": [Transaction], "sql": [Sql], "errors": [Error] }
```

**Transaction** — one per (type, name) in the minute:
`type` ("web"|"job"), `name`, `count`, `total`, `min`, `max`, `sumsq`,
`errors`, `apdex` ([satisfied, tolerating, frustrated]), `hist`, `queue`
(total queue ms), `breakdown` ({layer => exclusive ms}; layers: middleware,
controller, view, activerecord, database, external, cache, custom, job,
graphql), `segments` ([Segment]).

**Segment** — one per segment name within the transaction: `name`
(`<Layer prefix>/...`, e.g. `Database/users/select`,
`External/api.stripe.com/POST`, `GraphQL/field/Product.reviews`), `cat`
(layer), `count`, `total` (inclusive ms), `excl` (exclusive ms), `min`,
`max`, `txns` (transactions that touched it).

**Sql** — per (transaction, statement): `tx_type`, `tx`, `key` (md5 of the
obfuscated SQL), `sql` (obfuscated: no literals), `op`, `table`, `count`,
`txns`, `total`, `min`, `max`, `max_per_tx` (most executions in one
transaction; N+1 signal), `location` (app frame), `hist`, `slow` (executions
over the slow-query threshold).

**Error** — per (transaction, class, message): `tx_type`, `tx`, `class`,
`message`, `backtrace` (≤ 30 lines), `count`, `uri`, `last_at`.

### Trace

`tx_type`, `tx`, `ts`, `duration`, `uri`, `status`, `error` (class or null),
`segments` (total segment count), `breakdown`, `attributes`, and `tree`:
a nested node `[name, layer, start_ms, duration_ms, children, attrs?]`
with `start_ms` relative to the transaction start. `attrs` carries `sql`,
`key`, `loc` for SQL and `url`, `status` for external calls.

### Slow query

`tx_type`, `tx`, `uri`, `key`, `sql`, `op`, `table`, `duration`, `ts`,
`location`, `backtrace` (app frames), `explain` (plan text with literals
removed, or null).

### Runtime

Deltas since the previous flush: `elapsed_ms`, `cpu_ms`, `gc_count`,
`gc_major`, `gc_time_ms`, `allocations`; gauges: `rss_mb`,
`heap_live_slots`, `threads`, `db_pool_size`, `db_pool_busy`,
`db_pool_waiting`.
