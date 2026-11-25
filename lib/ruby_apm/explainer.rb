module RubyAPM
  # Runs EXPLAIN for sampled slow SELECTs on the reporter thread, with a
  # connection checked out of the same pool the query used. Plans carry the
  # query's real values (PostgreSQL substitutes binds), so every line has its
  # string and numeric literals replaced before shipping; only the planner's
  # own estimates (cost=, rows=, width=) and statistics lines are kept.
  class Explainer
    EXPLAINABLE = /\A\s*(SELECT|WITH)\b/i
    # Planner statistics, safe and needed by the plan analysis.
    STATS_LINE = /\A\s*(?:->\s*)?(?:Sort Method|Buckets|Rows Removed|Heap Blocks|Workers (?:Planned|Launched)|Planning|Execution|Batches|Memory Usage|Peak Memory|Disk Usage|Buffers|I\/O Timings|JIT):/
    ESTIMATES = /\((?:cost|actual)=[^)]*\)|\b(?:cost|rows|width|loops)=[\d.]+(?:\.\.[\d.]+)?/
    PLACEHOLDER = "\u0000"
    REEXPLAIN_AFTER = 600 # seconds before the same statement is explained again

    def initialize(config)
      @config = config
      @explained = {}
    end

    def explain(samples, limit: 10)
      return unless @config.explain_slow_queries

      now = Time.now.to_f
      @explained.delete_if { |_, at| now - at > REEXPLAIN_AFTER } if @explained.size > 5_000
      samples.sort_by { |q| -q[:duration] }.each do |q|
        break if limit <= 0
        next unless explainable?(q)
        next if (at = @explained[q[:key]]) && now - at < REEXPLAIN_AFTER

        @explained[q[:key]] = now
        limit -= 1
        q[:explain] = run(q)
      end
    end

    def obfuscate_plan(text)
      text.lines.map do |line|
        next line if line.match?(STATS_LINE)

        kept = []
        masked = line.gsub(ESTIMATES) { kept << Regexp.last_match(0); PLACEHOLDER }
        masked = SqlObfuscator.scrub(masked)
        masked.gsub(PLACEHOLDER) { kept.shift }
      end.join
    end

    private

    def explainable?(q)
      q[:raw_sql].is_a?(String) && q[:raw_sql].match?(EXPLAINABLE) && !q[:raw_sql].include?(";") &&
        q[:raw_sql].bytesize < 50_000
    end

    def idle_connection?(pool)
      stat = pool.stat
      stat[:idle].to_i.positive? || stat[:connections].to_i < stat[:size].to_i
    rescue StandardError
      false
    end

    def run(q)
      pool = q[:pool] || (defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connection_pool)
      return nil unless pool
      # Never compete with requests for a connection: skip when none is free.
      return "EXPLAIN skipped: connection pool busy" unless idle_connection?(pool)

      pool.with_connection do |conn|
        adapter = conn.adapter_name.to_s.downcase
        rows = if adapter.include?("postg")
                 # Never wait behind a migration's lock or run long on the
                 # reporter thread.
                 conn.transaction(requires_new: true) do
                   conn.execute("SET LOCAL statement_timeout = '2s'")
                   conn.execute("SET LOCAL lock_timeout = '200ms'")
                   conn.select_rows("EXPLAIN #{q[:raw_sql]}", "EXPLAIN", q[:binds] || [])
                 end
               elsif adapter.include?("sqlite")
                 # Plain EXPLAIN is VM bytecode with every literal in it.
                 conn.select_rows("EXPLAIN QUERY PLAN #{q[:raw_sql]}", "EXPLAIN", q[:binds] || []).map { |r| [r.last] }
               else
                 conn.select_rows("EXPLAIN #{q[:raw_sql]}", "EXPLAIN", q[:binds] || [])
               end
        obfuscate_plan(rows.map { |r| r.join(" | ") }.join("\n"))[0, 20_000]
      end
    rescue StandardError => e
      "EXPLAIN failed: #{e.class}"
    end
  end
end
