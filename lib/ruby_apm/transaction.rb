module RubyAPM
  # One unit of work: a web request or a background job. Lives in a
  # fiber-local slot while it runs and is handed to the aggregator when it
  # finishes. Metrics are accumulated as segments close, so the trace tree is
  # only an optional side product and can be truncated without losing totals.
  class Transaction
    CATEGORIES = %i[middleware controller view activerecord database external cache custom job graphql].freeze
    KEY = :__ruby_apm_transaction

    # name, category, start offset (ms), duration (ms), children, extra attrs
    class Segment
      attr_accessor :name, :category, :start, :duration, :children, :child_time, :token, :parent, :in_tree,
                    :fiber, :active_since, :accumulated, :statement, :location
      attr_writer :attrs

      def initialize(name, category, start, token, parent)
        @name = name
        @category = category
        @start = start
        @token = token || self
        @parent = parent
        @child_time = 0.0
        @duration = 0.0
        @active_since = start
        @accumulated = 0.0
        @fiber = Fiber.current
      end

      # Time this segment's fiber was actually running; excludes time it sat
      # suspended (GraphQL Dataloader) while other fibers did the work.
      def active_time(now)
        @active_since ? @accumulated + (now - @active_since) : @accumulated
      end

      # SQL details are only materialized when a trace is actually shipped.
      def attrs
        return @attrs unless @statement
        a = { "sql" => @statement.sql, "key" => @statement.key }
        a["loc"] = @location if @location
        @attrs ? @attrs.merge(a) : a
      end

      def to_wire(base_start)
        node = [name, category.to_s, (start - base_start).round(3), duration.round(3)]
        node << (children ? children.map { |c| c.to_wire(base_start) } : [])
        a = attrs
        node << a if a
        node
      end
    end

    # Per-transaction rollup of one segment name.
    class SegmentStat
      attr_accessor :category, :count, :total, :exclusive, :min, :max

      def initialize(category)
        @category = category
        @count = 0
        @total = 0.0
        @exclusive = 0.0
        @min = Float::INFINITY
        @max = 0.0
      end

      def add(duration, exclusive)
        @count += 1
        @total += duration
        @exclusive += exclusive
        @min = duration if duration < @min
        @max = duration if duration > @max
      end
    end

    SqlStat = Struct.new(:statement, :count, :total, :min, :max, :location, :hist, :slow)

    attr_reader :type, :started_at, :segments, :sql, :breakdown, :root, :attributes, :slow_queries
    attr_accessor :name, :status, :uri, :queue_time, :duration, :ignored
    attr_reader :gc_ms, :allocations
    attr_reader :error

    # Expected exceptions (see Config#ignored_errors) are not recorded as errors.
    def error=(error)
      @error = error unless @config.ignored_error?(error)
    end

    def self.current
      Thread.current[KEY]
    end

    def self.current=(txn)
      Thread.current[KEY] = txn
    end

    def initialize(type:, name: nil, uri: nil, config: RubyAPM.config)
      @type = type
      @name = name
      @uri = uri
      @config = config
      @started_at = Time.now.to_f
      @start = RubyAPM.clock
      @segments = {}
      @sql = {}
      @breakdown = Hash.new(0.0)
      @attributes = {}
      @slow_queries = []
      @segment_count = 0
      @max_segments = config.max_segments_per_trace
      @root = Segment.new(type == :job ? "Job" : "Middleware/Rack", type == :job ? :job : :middleware, @start, nil, nil)
      @root.children = []
      @root.in_tree = true
      @gc_start = GC.stat(:time).to_f
      @alloc_start = GC.stat(:total_allocated_objects)
      @stack = [@root]
    end

    def start_segment(name, category, token = nil)
      parent = @stack.last
      segment = Segment.new(name, category, RubyAPM.clock, token, parent)
      if parent.in_tree && @segment_count < @max_segments
        @segment_count += 1
        segment.in_tree = true
        (parent.children ||= []) << segment
      end
      @stack << segment
      segment
    end

    # Closes the segment matching +token+ (the segment itself when no token
    # was given at start, or the innermost one when omitted). It is
    # normally on top of the stack, but fibers (GraphQL Dataloader) can finish
    # segments out of order, so it is removed from wherever it sits. Segments
    # that never close are closed when the transaction finishes.
    #
    # +prune_below+ (ms) drops a fast, childless segment from the trace tree
    # while still counting it in the metrics; used for chatty GraphQL fields.
    def finish_segment(token = nil, attrs = nil, prune_below: nil)
      return if @stack.size <= 1

      index = token ? @stack.rindex { |s| s.token.equal?(token) } : @stack.size - 1
      return unless index&.positive?

      segment = @stack.delete_at(index)
      close(segment, RubyAPM.clock)
      segment.attrs = attrs if attrs
      prune(segment) if prune_below && segment.in_tree && segment.children.nil? && segment.duration < prune_below
      segment
    end

    def current_segment
      @stack.last
    end

    # Called when a fiber is about to be suspended (GraphQL Dataloader). Its
    # open segments stop accruing time and leave the stack, so segments of
    # the fibers that run meanwhile get correct parents and nothing is
    # counted twice.
    def suspend_fiber(fiber = Fiber.current)
      segments = @stack.drop(1).select { |seg| seg.fiber.equal?(fiber) }
      return if segments.empty?

      now = RubyAPM.clock
      segments.each do |seg|
        seg.accumulated += now - seg.active_since
        seg.active_since = nil
      end
      @stack -= segments
      ((@suspended ||= {})[fiber] ||= []).concat(segments)
    end

    def resume_fiber(fiber = Fiber.current)
      segments = @suspended&.delete(fiber)
      return unless segments

      now = RubyAPM.clock
      segments.each { |seg| seg.active_since = now }
      @stack.concat(segments)
    end

    def record_sql(statement, duration, location)
      stat = @sql[statement.key]
      unless stat
        return if @sql.size >= @config.max_sql_statements
        stat = @sql[statement.key] = SqlStat.new(statement, 0, 0.0, Float::INFINITY, 0.0, nil, Hash.new(0), 0)
      end
      stat.count += 1
      stat.total += duration
      stat.max = duration if duration > stat.max
      stat.min = duration if duration < stat.min
      stat.hist[Histogram.index(duration)] += 1
      stat.slow += 1 if duration >= @config.slow_query_threshold
      stat.location ||= location
    end

    MAX_SLOW_PER_TRANSACTION = 10

    # Keeps the slowest individual executions so the server can show the
    # exact statement, backtrace and query plan behind a latency spike.
    def record_slow_query(sample)
      if @slow_queries.size < MAX_SLOW_PER_TRANSACTION
        @slow_queries << sample
      else
        fastest = @slow_queries.min_by { |q| q[:duration] }
        @slow_queries[@slow_queries.index(fastest)] = sample if fastest[:duration] < sample[:duration]
      end
    end

    def finish
      now = RubyAPM.clock
      @suspended&.each_value { |segs| segs.each { |seg| close(seg, now) } }
      @suspended = nil
      close(@stack.pop, now) while @stack.size > 1
      close(@root, now)
      @stack.clear
      @duration = @root.duration
      # Process-wide counters, so approximate under concurrency; shown on traces only.
      @gc_ms = GC.stat(:time).to_f - @gc_start
      @allocations = GC.stat(:total_allocated_objects) - @alloc_start
    end

    def error?
      !error.nil? || (status && status >= 500)
    end

    def segment_count
      @segment_count
    end

    def trace_wire
      @root.to_wire(@start)
    end

    private

    def prune(segment)
      siblings = segment.parent&.children
      return unless siblings

      i = siblings.rindex { |c| c.equal?(segment) }
      return unless i

      siblings.delete_at(i)
      segment.parent.children = nil if siblings.empty? && !segment.parent.equal?(@root)
      segment.in_tree = false
      @segment_count -= 1
    end

    def close(segment, now)
      duration = segment.active_time(now)
      duration = 0.0 if duration.negative?
      segment.duration = duration
      exclusive = duration - segment.child_time
      exclusive = 0.0 if exclusive.negative?

      segment.parent.child_time += duration if segment.parent
      @breakdown[segment.category] += exclusive

      stat = (@segments[segment.name] ||= SegmentStat.new(segment.category))
      stat.add(duration, exclusive)
    end
  end
end
