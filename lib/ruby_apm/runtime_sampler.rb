module RubyAPM
  # Process-level health sampled once per flush: memory, GC, CPU,
  # allocations, threads and the ActiveRecord connection pool. Counters are
  # sent as deltas since the previous sample so the server can sum them.
  class RuntimeSampler
    def initialize
      @last = nil
      @last_at = nil
    end

    def sample
      now = RubyAPM.clock
      gc = GC.stat
      current = {
        gc_count: gc[:count], gc_major: gc[:major_gc_count], gc_time: gc[:time].to_f,
        allocations: gc[:total_allocated_objects],
        cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID, :float_millisecond)
      }
      deltas = @last ? current.to_h { |k, v| [k, [v - @last[k], 0].max] } : nil
      elapsed = @last_at ? now - @last_at : nil
      @last = current
      @last_at = now
      return nil unless deltas && elapsed&.positive?

      {
        "elapsed_ms" => elapsed.round(1), "rss_mb" => rss_mb, "heap_live_slots" => gc[:heap_live_slots],
        "gc_count" => deltas[:gc_count], "gc_major" => deltas[:gc_major], "gc_time_ms" => deltas[:gc_time].round(2),
        "allocations" => deltas[:allocations], "cpu_ms" => deltas[:cpu].round(1),
        "threads" => Thread.list.size
      }.merge(db_pool)
    rescue StandardError
      nil
    end

    private

    def rss_mb
      if File.readable?("/proc/self/statm")
        pages = File.read("/proc/self/statm").split[1].to_i
        (pages * 4096 / 1_048_576.0).round(1)
      else
        (`ps -o rss= -p #{Process.pid}`.to_i / 1024.0).round(1)
      end
    rescue StandardError
      nil
    end

    def db_pool
      return {} unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

      stat = ::ActiveRecord::Base.connection_pool.stat
      { "db_pool_size" => stat[:size], "db_pool_busy" => stat[:busy], "db_pool_waiting" => stat[:waiting] }
    rescue StandardError
      {}
    end
  end
end
