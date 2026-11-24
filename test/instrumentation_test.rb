require "test_helper"

class Pricing
  include RubyAPM::MethodTracer
  def quote(n, discount: 0) = n * 2 - discount
  trace_method :quote
  def self.region = "eu"
  trace_class_method :region
end

class InstrumentationTest < RubyAPMTest
  def test_web_request_records_ar_db_and_custom_segments
    Widget.delete_all
    3.times { |i| Widget.create!(name: "w#{i}", price: i) }
    setup # discard writes above (they were outside a request anyway)

    app = lambda do |_env|
      RubyAPM.set_transaction_name("WidgetsController#index")
      Widget.where("price >= ?", 0).to_a
      Widget.find(Widget.first.id)
      assert_equal 9, Pricing.new.quote(5, discount: 1)
      assert_equal "eu", Pricing.region
      [200, {}, ["ok"]]
    end
    status, = run_request(app)
    assert_equal 200, status

    bucket, = drained
    stat = bucket.transactions[[:web, "WidgetsController#index"]]
    assert_equal 1, stat.count
    names = stat.segments.keys
    assert_includes names, "ActiveRecord/Widget/load"
    assert_includes names, "ActiveRecord/Widget/find"
    assert_includes names, "Database/widgets/select"
    assert_includes names, "Custom/Pricing#quote"
    assert_includes names, "Custom/Pricing.region"
    assert_operator stat.breakdown[:database], :>, 0
    assert_operator stat.breakdown[:activerecord], :>, 0
    refute bucket.sql.empty?
    sql = bucket.sql.values.map { |a| a.statement.sql }
    assert(sql.any? { |s| s.include?(%(WHERE (price >= ?))) }, sql.inspect)
  end

  def test_n_plus_one_counts_per_transaction
    Widget.create!(name: "n1", price: 1) if Widget.count.zero?
    setup
    app = lambda do |_env|
      RubyAPM.set_transaction_name("WidgetsController#n1")
      12.times { |i| Widget.where(id: i).first }
      [200, {}, []]
    end
    run_request(app)
    bucket, = drained
    agg = bucket.sql.values.max_by(&:count)
    assert_equal 12, agg.max_per_tx
    assert_equal 1, agg.tx_count
  end

  def test_errors_and_traces
    RubyAPM.config.trace_threshold = 0
    app = ->(_env) { RubyAPM.set_transaction_name("BoomController#show"); raise ArgumentError, "bad id 42" }
    assert_raises(ArgumentError) { run_request(app) }
    bucket, traces = drained
    stat = bucket.transactions[[:web, "BoomController#show"]]
    assert_equal 1, stat.errors
    err = bucket.errors.values.first
    assert_equal "ArgumentError", err["class"]
    assert_equal 1, traces.size
    assert_equal "ArgumentError", traces.first["error"]
  ensure
    RubyAPM.config.trace_threshold = 300.0
  end

  # 500s whose exception never reaches the middleware still get a cause.
  def test_server_errors_without_an_escaping_exception
    require "ruby_apm/error_subscriber"
    shown = ->(env) { RubyAPM.set_transaction_name("Shown#x"); env["action_dispatch.exception"] = KeyError.new("caught by ShowExceptions"); [500, {}, []] }
    reported = lambda do |_|
      RubyAPM.set_transaction_name("Graphql#execute")
      RubyAPM::ErrorSubscriber.new.report(ZeroDivisionError.new("rescued and reported"), handled: true, severity: :error, context: {})
      [500, {}, []]
    end
    bare = ->(_) { RubyAPM.set_transaction_name("Bare#x"); [503, {}, []] }
    fine = ->(_) { RubyAPM.set_transaction_name("Fine#x"); RubyAPM::ErrorSubscriber.new.report(IOError.new("retried"), handled: true, severity: :warning, context: {}); [200, {}, []] }
    [shown, reported, bare, fine].each { |app| run_request(app) }

    bucket, = drained
    by_tx = bucket.errors.values.to_h { |e| [e["tx"], e] }
    assert_equal "KeyError", by_tx["Shown#x"]["class"]
    assert_equal "ZeroDivisionError", by_tx["Graphql#execute"]["class"]
    assert_equal "HTTP 503", by_tx["Bare#x"]["class"]
    assert_match "without an exception reaching RubyAPM", by_tx["Bare#x"]["message"]
    refute by_tx.key?("Fine#x"), "a handled report on a 200 is not an error"
    assert_equal [1, 1, 1, 0], %w[Shown#x Graphql#execute Bare#x Fine#x].map { |n| bucket.transactions[[:web, n]].errors }
  end

  def test_backtraces_keep_app_frames_below_deep_library_stacks
    deep = Array.new(60) { |i| "/usr/local/bundle/gems/arel/to_sql.rb:#{i}:in `visit'" }
    app = ["/app/app/services/maintenance.rb:53:in `prune'", "/app/app/services/maintenance.rb:12:in `run'"]
    trimmed = RubyAPM::Aggregator.trim_backtrace(deep + app + deep)
    assert_equal deep.first(8), trimmed.first(8)
    assert_match "library frames omitted", trimmed[8]
    assert_equal app, trimmed[9, 2]
    short = deep.first(5)
    assert_equal short, RubyAPM::Aggregator.trim_backtrace(short)
  end

  def test_ignored_paths_and_unnamed_requests
    run_request(->(_) { [200, {}, []] }, "/assets/app.css")
    run_request(->(_) { [404, {}, []] }, "/nope")
    bucket, = drained
    assert_equal [[:web, "Rack/404"]], bucket.transactions.keys
  end

  def test_in_transaction_for_background_work
    RubyAPM.in_transaction("Rake/import") { Widget.count }
    bucket, = drained
    stat = bucket.transactions[[:job, "Rake/import"]]
    assert_equal 1, stat.count
    assert stat.segments.key?("ActiveRecord/Widget/count")
  end

  def test_reporter_payload_roundtrip
    run_request(->(_) { RubyAPM.set_transaction_name("X#y"); Widget.count; [200, {}, []] })
    reporter = RubyAPM.reporter
    sent = nil
    reporter.define_singleton_method(:post) { |body| sent = body; true }
    assert reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(sent)).read)
    assert_equal 1, doc["v"]
    tx = doc["buckets"].first["transactions"].find { |t| t["name"] == "X#y" }
    assert_equal 1, tx["count"]
    assert tx["segments"].any? { |s| s["name"] == "ActiveRecord/Widget/count" }
  ensure
    reporter.singleton_class.send(:remove_method, :post)
  end

  def test_failed_flush_is_retried
    run_request(->(_) { RubyAPM.set_transaction_name("Retry#me"); [200, {}, []] })
    reporter = RubyAPM.reporter
    calls = []
    reporter.define_singleton_method(:post) { |body| calls << body; calls.size > 1 }
    refute reporter.flush
    assert reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(calls.last)).read)
    assert(doc["buckets"].flat_map { |b| b["transactions"] }.any? { |t| t["name"] == "Retry#me" })
  ensure
    reporter.singleton_class.send(:remove_method, :post)
  end
end

class SlowQueryTest < RubyAPMTest
  def test_slow_queries_are_sampled_with_plan_and_histogram
    RubyAPM.config.slow_query_threshold = 0
    RubyAPM.config.sql_backtrace_threshold = 0
    run_request(->(_) { RubyAPM.set_transaction_name("Slow#q"); Widget.where("price > ?", 5).to_a; [200, {}, []] })
    reporter = RubyAPM.reporter
    sent = nil
    reporter.define_singleton_method(:post) { |body| sent = body; true }
    reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(sent)).read)
    q = doc["slow_queries"].find { |s| s["sql"].include?("price > ?") }
    assert q, doc["slow_queries"].inspect
    assert_equal "Slow#q", q["tx"]
    refute_includes q.to_s, "price > 5"
    assert q["explain"].is_a?(String)
    refute_match(/EXPLAIN failed/, q["explain"])
    sql = doc["buckets"].first["sql"].find { |s| s["key"] == q["key"] }
    assert_equal 1, sql["hist"].values.sum
    assert_equal 1, sql["slow"]
  ensure
    RubyAPM.config.slow_query_threshold = 100.0
    RubyAPM.config.sql_backtrace_threshold = 10.0
    reporter.singleton_class.send(:remove_method, :post)
  end

  def test_plan_obfuscation_keeps_costs
    e = RubyAPM::Explainer.new(RubyAPM.config)
    plan = "Seq Scan on users  (cost=0.00..35.50 rows=10 width=4)\n  Filter: ((email)::text = 'bob@x.com'::text AND (age > 42))"
    out = e.obfuscate_plan(plan)
    assert_includes out, "cost=0.00..35.50 rows=10"
    refute_includes out, "bob@x.com"
    refute_includes out, "42"
  end
end

class IgnoredErrorTest < RubyAPMTest
  class NotFound < StandardError; end

  def test_expected_errors_are_not_counted
    RubyAPM.config.ignored_errors << "IgnoredErrorTest::NotFound"
    app = ->(_) { RubyAPM.set_transaction_name("Missing#show"); RubyAPM.notice_error(NotFound.new("x")); [404, {}, []] }
    run_request(app)
    bucket, = drained
    assert_equal 0, bucket.transactions[[:web, "Missing#show"]].errors
    assert_empty bucket.errors
  ensure
    RubyAPM.config.ignored_errors.delete("IgnoredErrorTest::NotFound")
  end
end

class RuntimeTest < RubyAPMTest
  def test_runtime_sample_is_a_delta_after_the_first_call
    sampler = RubyAPM::RuntimeSampler.new
    assert_nil sampler.sample
    Array.new(10_000) { Object.new }
    s = sampler.sample
    assert_operator s["allocations"], :>=, 10_000
    assert_operator s["rss_mb"], :>, 1
    assert s.key?("db_pool_size")
  end

  def test_traces_carry_gc_and_allocations
    RubyAPM.config.trace_threshold = 0
    run_request(->(_) { RubyAPM.set_transaction_name("Alloc#y"); Array.new(5_000) { "x" * 10 }; [200, {}, []] })
    _, traces = drained
    attrs = traces.find { |t| t["tx"] == "Alloc#y" }["attributes"]
    assert_operator attrs["allocations"], :>=, 5_000
    assert attrs.key?("gc_ms")
  ensure
    RubyAPM.config.trace_threshold = 300.0
  end
end

class ExplainerPoolTest < RubyAPMTest
  FakePool = Struct.new(:stat)

  def test_skips_explain_when_pool_has_no_free_connection
    e = RubyAPM::Explainer.new(RubyAPM.config)
    busy = FakePool.new({ size: 2, connections: 2, busy: 2, idle: 0 })
    q = { key: "k", raw_sql: "SELECT 1", duration: 500, pool: busy }
    e.explain([q])
    assert_match(/skipped/, q[:explain])
  end
end

class ReporterRobustnessTest < RubyAPMTest
  def test_unserializable_attribute_does_not_lose_metrics
    RubyAPM.config.trace_threshold = 0
    run_request(lambda do |_|
      RubyAPM.set_transaction_name("Odd#attr")
      RubyAPM.add_attribute("when", Time.at(0))
      RubyAPM.add_attribute("obj", Object.new)
      [200, {}, []]
    end)
    reporter = RubyAPM.reporter
    sent = nil
    reporter.define_singleton_method(:post) { |body| sent = body; true }
    assert reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(sent)).read)
    assert(doc["buckets"].flat_map { |b| b["transactions"] }.any? { |t| t["name"] == "Odd#attr" })
    assert doc["buckets"].all? { |b| b["id"].is_a?(String) }
    trace = doc["traces"].find { |t| t["tx"] == "Odd#attr" }
    assert_kind_of String, trace["attributes"]["when"]
  ensure
    RubyAPM.config.trace_threshold = 300.0
    reporter.singleton_class.send(:remove_method, :post)
  end

  def test_retried_buckets_keep_their_id
    run_request(->(_) { RubyAPM.set_transaction_name("Retry#id"); [200, {}, []] })
    reporter = RubyAPM.reporter
    bodies = []
    reporter.define_singleton_method(:post) { |body| bodies << body; bodies.size > 1 }
    reporter.flush
    reporter.flush
    ids = bodies.map { |b| MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(b)).read)["buckets"].map { |x| x["id"] } }
    assert_equal ids[0], ids[1] & ids[0]
  ensure
    reporter.singleton_class.send(:remove_method, :post)
  end

  def test_sql_min_is_per_execution
    Widget.create!(name: "m", price: 1) if Widget.count.zero?
    run_request(->(_) { RubyAPM.set_transaction_name("Min#sql"); 3.times { Widget.where(price: 1).to_a }; [200, {}, []] })
    bucket, = drained
    agg = bucket.sql.values.find { |a| a.statement.sql.include?('"price" = ?') }
    assert_operator agg.min, :<=, agg.total / agg.count
  end
end

class DisabledAgentTest < Minitest::Test
  def test_endpoint_with_a_path_prefix_keeps_it
    reporter = RubyAPM::Reporter.new(RubyAPM::Config.new.tap { |c| c.endpoint = "http://rubyapm.apm.svc.cluster.local/apm/" }, RubyAPM.aggregator)
    assert_equal "/apm/api/v1/ingest", reporter.send(:ingest_uri).path
    reporter = RubyAPM::Reporter.new(RubyAPM::Config.new.tap { |c| c.endpoint = "http://localhost:4400" }, RubyAPM.aggregator)
    assert_equal "/api/v1/ingest", reporter.send(:ingest_uri).path
  end

  def test_middleware_is_inert_when_the_agent_did_not_start
    RubyAPM.instance_variable_set(:@started, false)
    called = false
    status, = RubyAPM::Middleware.new(->(_) { called = true; [200, {}, []] }).call(Rack::MockRequest.env_for("/x"))
    assert called
    assert_equal 200, status
    assert_nil RubyAPM::Transaction.current
    assert RubyAPM.aggregator.drain.first.empty?
  ensure
    RubyAPM.instance_variable_set(:@started, true)
  end
end
