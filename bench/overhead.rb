# Measures what the agent adds to a request: a Rack app doing a realistic
# amount of ActiveRecord work (15 queries, 120 records instantiated), run
# with and without the agent's middleware + subscribers.
#
#   bundle exec ruby bench/overhead.rb
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "benchmark"
require "active_record"
require "rack"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define { create_table(:items) { |t| t.string :name; t.integer :n } }
class Item < ActiveRecord::Base; end
Item.insert_all(Array.new(500) { |i| { name: "item #{i}", n: i } })

WORK = lambda do |_env|
  5.times { |i| Item.where(n: i * 10).first }
  5.times { |i| Item.where("n > ?", i * 50).limit(20).to_a }
  5.times { Item.count }
  [200, {}, ["ok"]]
end

def run(app, n)
  env = Rack::MockRequest.env_for("/items")
  GC.start
  Benchmark.realtime { n.times { app.call(env.dup) } }
end

N = 3_000
plain = WORK
run(plain, 300) # warm up
base = run(plain, N)

require "ruby_apm"
RubyAPM.configure { |c| c.enabled = true; c.api_key = "bench"; c.app_name = "Bench"; c.flush_interval = 3600 }
RubyAPM.start!
# Never ship benchmark data anywhere (the reporter also flushes at exit).
RubyAPM.reporter.define_singleton_method(:post) { |_body| true }
named = ->(env) { RubyAPM.set_transaction_name("ItemsController#index"); WORK.call(env) }
instrumented = RubyAPM::Middleware.new(named)
run(instrumented, 300)
with_agent = run(instrumented, N)

reporter = RubyAPM.reporter
bytes = nil
reporter.define_singleton_method(:post) { |body| bytes = body.bytesize; true }
at_exit { reporter.define_singleton_method(:post) { |_body| true } }
flush = Benchmark.realtime { reporter.flush }

per_req = (with_agent - base) / N * 1_000_000
puts format("without agent: %7.1f µs/request", base / N * 1_000_000)
puts format("with agent:    %7.1f µs/request", with_agent / N * 1_000_000)
puts format("overhead:      %7.1f µs/request (%.1f%%), ~%.1f µs per instrumented event", per_req, (with_agent / base - 1) * 100, per_req / 46)
puts format("flush of %d requests: %.1f ms, %d bytes on the wire", N + 300, flush * 1000, bytes.to_i)
