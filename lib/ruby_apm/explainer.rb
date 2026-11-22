module RubyAPM
  # Runs EXPLAIN for sampled slow SELECTs on the reporter thread, with a
  # connection checked out of the same pool the query used. Literal values
  # in filter conditions are stripped from the plan before it is shipped.
  class Explainer
    EXPLAINABLE = /\A\s*(SELECT|WITH)\b/i
    LITERAL_LINE = /(Filter|Cond|Recheck Cond|Index Cond|Hash Cond|Merge Cond|Join Filter|One-Time Filter):/
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
        next line unless line.match?(LITERAL_LINE)
        line.gsub(SqlObfuscator::STRINGS, "?").gsub(/(?<=[\s(=<>,])-?\d+(?:\.\d+)?(?=[\s),:]|$)/, "?")
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
        rows = conn.select_rows("EXPLAIN #{q[:raw_sql]}", "EXPLAIN", q[:binds] || [])
        obfuscate_plan(rows.map { |r| r.join(" | ") }.join("\n"))[0, 20_000]
      end
    rescue StandardError => e
      "EXPLAIN failed: #{e.class}"
    end
  end
end
