module RubyAPM
  # Folds finished transactions into per-minute buckets. The hot path holds the
  # mutex only while merging a handful of hashes; the reporter swaps the whole
  # state out in O(1) and serializes it without the lock.
  class Aggregator
    OVERFLOW_NAME = "Other/overflow"
    MAX_ERROR_GROUPS = 500
    MAX_BACKTRACE_LINES = 30

    class TxStat
      attr_reader :count, :total, :min, :max, :sumsq, :errors, :apdex, :hist, :breakdown, :segments,
                  :queue_time, :segment_total

      def initialize
        @count = 0
        @total = 0.0
        @min = Float::INFINITY
        @max = 0.0
        @sumsq = 0.0
        @errors = 0
        @apdex = [0, 0, 0]
        @hist = Array.new(Histogram::SIZE, 0)
        @breakdown = Hash.new(0.0)
        @segments = {}
        @queue_time = 0.0
      end

      def add(txn, apdex_t)
        d = txn.duration
        @count += 1
        @total += d
        @sumsq += d * d
        @min = d if d < @min
        @max = d if d > @max
        @hist[Histogram.index(d)] += 1
        @queue_time += txn.queue_time.to_f

        if txn.error?
          @errors += 1
          @apdex[2] += 1
        elsif d <= apdex_t
          @apdex[0] += 1
        elsif d <= apdex_t * 4
          @apdex[1] += 1
        else
          @apdex[2] += 1
        end

        txn.breakdown.each { |cat, ms| @breakdown[cat] += ms }
        txn.segments.each do |name, s|
          agg = (@segments[name] ||= [s.category, 0, 0.0, 0.0, Float::INFINITY, 0.0, 0])
          agg[1] += s.count
          agg[2] += s.total
          agg[3] += s.exclusive
          agg[4] = s.min if s.min < agg[4]
          agg[5] = s.max if s.max > agg[5]
          agg[6] += 1 # transactions that touched this segment
        end
      end

      def to_wire(type, name)
        {
          "type" => type.to_s, "name" => name, "count" => @count, "total" => @total.round(3),
          "min" => @min.round(3), "max" => @max.round(3), "sumsq" => @sumsq.round(3), "errors" => @errors,
          "apdex" => @apdex, "hist" => sparse(@hist), "queue" => @queue_time.round(3),
          "breakdown" => @breakdown.transform_keys(&:to_s).transform_values { |v| v.round(3) },
          "segments" => @segments.map do |seg_name, (cat, count, total, excl, min, max, txns)|
            { "name" => seg_name, "cat" => cat.to_s, "count" => count, "total" => total.round(3),
              "excl" => excl.round(3), "min" => min.round(3), "max" => max.round(3), "txns" => txns }
          end
        }
      end

      private

      def sparse(hist)
        out = {}
        hist.each_with_index { |c, i| out[i] = c if c.positive? }
        out
      end
    end

    class SqlAgg
      attr_accessor :statement, :count, :total, :min, :max, :max_per_tx, :location, :tx_count, :hist, :slow

      def initialize(statement)
        @statement = statement
        @count = 0
        @tx_count = 0
        @total = 0.0
        @min = Float::INFINITY
        @max = 0.0
        @max_per_tx = 0
        @hist = Hash.new(0)
        @slow = 0
      end

      def add(stat)
        @count += stat.count
        @tx_count += 1
        @total += stat.total
        @max = stat.max if stat.max > @max
        @min = stat.min if stat.min < @min
        @max_per_tx = stat.count if stat.count > @max_per_tx
        @location ||= stat.location
        @slow += stat.slow
        stat.hist.each { |i, c| @hist[i] += c }
      end

      def to_wire(type, tx_name)
        s = @statement
        { "tx_type" => type.to_s, "tx" => tx_name, "key" => s.key, "sql" => s.sql, "op" => s.operation, "table" => s.table,
          "count" => @count, "txns" => @tx_count, "total" => @total.round(3), "min" => @min.round(3),
          "max" => @max.round(3), "max_per_tx" => @max_per_tx, "location" => @location,
          "hist" => @hist, "slow" => @slow }
      end
    end

    Bucket = Struct.new(:transactions, :sql, :errors)

    def initialize(config)
      @config = config
      @mutex = Mutex.new
      reset!
    end

    def record(txn)
      return if txn.ignored || txn.name.nil?

      minute = (txn.started_at / 60).floor * 60
      trace = trace_candidate(txn)

      @mutex.synchronize do
        bucket = (@buckets[minute] ||= Bucket.new({}, {}, {}))
        name = txn.name
        key = [txn.type, name]
        unless bucket.transactions.key?(key) || @names.include?(key)
          if @names.size >= @config.max_transaction_names
            name = OVERFLOW_NAME
            key = [txn.type, name]
          else
            @names << key
          end
        end
        (bucket.transactions[key] ||= TxStat.new).add(txn, @config.apdex_t)

        txn.sql.each_value do |stat|
          sql_key = [txn.type, name, stat.statement.key]
          agg = bucket.sql[sql_key]
          unless agg
            next if bucket.sql.size >= @config.max_sql_statements
            agg = bucket.sql[sql_key] = SqlAgg.new(stat.statement)
          end
          agg.add(stat)
        end

        record_error(bucket, txn, name) if txn.error

        add_trace(trace) if trace
        txn.slow_queries.each { |q| add_slow_query(q.merge(tx_type: txn.type.to_s, tx: name, uri: txn.uri)) }
      end
    end

    # Returns everything recorded so far and starts fresh.
    def drain
      @mutex.synchronize do
        buckets = @buckets
        traces = @traces
        @drained_slow_queries = @slow_queries
        reset!
        [buckets, traces]
      end
    end

    # Puts undelivered data back so the next flush retries it, keeping at most
    # +max_minutes+ of history to bound memory while the server is down.
    def restore(payload_buckets, max_minutes: 10)
      @mutex.synchronize do
        @pending = (payload_buckets + @pending).last(max_minutes)
      end
    end

    # Slow query samples taken by the last #drain.
    def take_slow_queries
      @mutex.synchronize do
        q = @drained_slow_queries || []
        @drained_slow_queries = nil
        q
      end
    end

    def take_pending
      @mutex.synchronize do
        pending = @pending
        @pending = []
        pending
      end
    end

    def empty?
      @mutex.synchronize { @buckets.empty? && @traces.empty? && @pending.empty? }
    end

    def reset!
      @buckets = {}
      @traces = []
      @slow_queries = []
      @names ||= Set.new
      @pending ||= []
    end

    private

    def trace_candidate(txn)
      return nil if txn.duration < @config.trace_threshold && !txn.error
      {
        "tx_type" => txn.type.to_s, "tx" => txn.name, "ts" => txn.started_at.round(3), "duration" => txn.duration.round(3),
        "uri" => txn.uri, "status" => txn.status, "error" => txn.error && error_class(txn.error),
        "segments" => txn.segment_count, "breakdown" => txn.breakdown.transform_keys(&:to_s).transform_values { |v| v.round(3) },
        "tree" => txn.trace_wire,
        "attributes" => txn.attributes.merge("gc_ms" => txn.gc_ms&.round(2), "allocations" => txn.allocations).compact
      }
    end

    def add_trace(trace)
      limit = @config.max_traces_per_flush
      same = @traces.index { |t| t["tx"] == trace["tx"] && t["tx_type"] == trace["tx_type"] }
      if same
        @traces[same] = trace if @traces[same]["duration"] < trace["duration"]
      elsif @traces.size < limit
        @traces << trace
      else
        fastest = @traces.each_with_index.min_by { |t, _| t["duration"] }
        @traces[fastest[1]] = trace if fastest[0]["duration"] < trace["duration"]
      end
    end

    def add_slow_query(sample)
      if @slow_queries.size < @config.max_slow_queries_per_flush
        @slow_queries << sample
      else
        i = @slow_queries.each_with_index.min_by { |q, _| q[:duration] }[1]
        @slow_queries[i] = sample if @slow_queries[i][:duration] < sample[:duration]
      end
    end

    def record_error(bucket, txn, name)
      error = txn.error
      klass = error_class(error)
      message = error.respond_to?(:message) ? error.message.to_s[0, 500] : error.to_s[0, 500]
      key = [txn.type, name, klass, message]
      entry = bucket.errors[key]
      unless entry
        return if bucket.errors.size >= MAX_ERROR_GROUPS
        backtrace = error.respond_to?(:backtrace) ? Array(error.backtrace).first(MAX_BACKTRACE_LINES) : []
        entry = bucket.errors[key] = { "tx_type" => txn.type.to_s, "tx" => name, "class" => klass,
                                       "message" => message, "backtrace" => backtrace, "count" => 0, "uri" => txn.uri }
      end
      entry["count"] += 1
      entry["last_at"] = txn.started_at.round(3)
    end

    def error_class(error)
      error.is_a?(Exception) ? error.class.name : error.to_s
    end
  end
end
