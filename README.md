# ruby_apm

The RubyAPM agent for Rails: measures where each request and job spends its
time (controller Ruby, views, ActiveRecord, the database, GraphQL resolvers,
external APIs, cache, jobs, your own classes), aggregates it in-process per
minute, and ships a compact gzipped MessagePack batch to a RubyAPM server
every 10 seconds. Nothing is sent per request, and SQL literals never leave
the process.

```ruby
gem "ruby_apm", git: "https://github.com/christianbpedersen/ruby_apm.git", tag: "v0.2.0"

# config/initializers/ruby_apm.rb
RubyAPM.configure do |c|
  c.app_name = "MyApp"
  c.api_key  = ENV["RUBY_APM_API_KEY"]     # reporting is off without a key
  c.endpoint = ENV["RUBY_APM_ENDPOINT"]    # your RubyAPM server, e.g. https://apm.example.com
end
```

The wire format between agent and server is documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## API

```ruby
RubyAPM.trace("Custom/Checkout/fraud check") { ... }   # time a block
RubyAPM.set_transaction_name("Webhooks/stripe")        # rename the current transaction
RubyAPM.add_attribute(:tenant, tenant.id)               # shown on traces
RubyAPM.notice_error(e)                                 # record a handled exception
RubyAPM.ignore_transaction!                             # drop this one (health checks…)
RubyAPM.in_transaction("Rake/import") { ... }           # instrument work outside requests/jobs

class PricingService
  include RubyAPM::MethodTracer
  trace_method :quote                 # Custom/PricingService#quote
  trace_class_method :for_region      # Custom/PricingService.for_region
end
```

Sidekiq workers are instrumented automatically when Sidekiq is loaded
(ActiveJob jobs on Sidekiq report under the job class name).

GraphQL schemas are instrumented automatically. To configure the tracer
yourself:

```ruby
class AppSchema < GraphQL::Schema
  trace_with RubyAPM::Instrumentation::GraphQL::Trace, trace_scalars: false
end
```

## Configuration

| Setting | Default | |
|---|---|---|
| `flush_interval` | 10 | seconds between batches |
| `apdex_t` | 500 | ms |
| `trace_threshold` | 300 | ms; slower transactions are trace candidates |
| `max_traces_per_flush` | 20 | slowest per transaction name |
| `slow_query_threshold` | 100 | ms; sampled with backtrace and EXPLAIN |
| `explain_slow_queries` | true | runs EXPLAIN on the reporter thread |
| `sql_backtrace_threshold` | 10 | ms; records the calling app frame |
| `n_plus_one_threshold` | 10 | identical statements per request |
| `graphql_field_trace_threshold` | 1 | ms; faster fields are counted but not kept in traces |
| `ignored_errors` | RecordNotFound, RoutingError, … | not counted as errors |
| `ignore_paths` | `/assets`, `/up`, `/favicon` | |
| `auto_instrument_paths` | `[]` | e.g. `%w[app/services]` |
| `instrument_instantiation` | false | split model instantiation out of ActiveRecord time |
| `revision` | `RUBY_APM_REVISION`, `REVISION` file or `git rev-parse` | deploy markers |

Every `RUBY_APM_*` variable also accepts its pre-rename `NEW_FENIC_*` name, and
`NewFenic` remains an alias of `RubyAPM`, so apps set up for 0.1 keep reporting.

Run the tests with `bundle exec rake test` and the overhead benchmark with
`bundle exec ruby bench/overhead.rb`.
