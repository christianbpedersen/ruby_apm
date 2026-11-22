require "time"
require "active_support/notifications"

module RubyAPM
  # Turns Rails' own ActiveSupport::Notifications events into segments. Evented
  # listeners (start/finish) give us proper nesting without monkey patching.
  module Subscribers
    # Base listener: opens a segment on start, closes it on finish. The payload
    # hash is the same object in both callbacks, so it is the matching token.
    class Segment
      def initialize(category, &namer)
        @category = category
        @namer = namer
      end

      def start(_event, _id, payload)
        txn = Transaction.current
        return unless txn

        name = @namer.call(payload)
        txn.start_segment(name, @category, payload) if name
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(_event, _id, payload)
        txn = Transaction.current
        txn&.finish_segment(payload)
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def publish_event(*); end
    end

    class ProcessAction < Segment
      def initialize
        super(:controller) { |p| Names.controller(p[:controller], p[:action]) }
      end

      def start(event, id, payload)
        txn = Transaction.current
        return unless txn

        # The first controller to run names the request; forwarded or nested
        # dispatches are just segments.
        txn.name ||= "#{payload[:controller]}##{payload[:action]}"
        txn.attributes["format"] ||= payload[:format].to_s if payload[:format]
        txn.attributes["method"] ||= payload[:method] if payload[:method]
        super
      end

      def finish(event, id, payload)
        txn = Transaction.current
        return unless txn

        super
        txn.status ||= payload[:status].to_i if payload[:status]
        if (error = payload[:exception_object])
          txn.error ||= error
          txn.status ||= 500
        end
      end
    end

    class Sql < Segment
      SKIP = %w[SCHEMA EXPLAIN].freeze

      def initialize
        super(:database) { nil }
      end

      def start(_event, _id, payload)
        txn = Transaction.current
        return unless txn
        return if SKIP.include?(payload[:name])

        if payload[:cached]
          txn.start_segment("Database/query cache", :cache, payload)
          return
        end

        statement = SqlObfuscator.call(payload[:sql])
        txn.start_segment(statement.segment_name, :database, payload).statement = statement
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(_event, _id, payload)
        txn = Transaction.current
        return unless txn
        return if SKIP.include?(payload[:name])

        segment = txn.finish_segment(payload)
        statement = segment&.statement
        return unless statement

        config = RubyAPM.config
        location = nil
        if segment.duration >= config.sql_backtrace_threshold
          frames = Subscribers.app_backtrace
          location = frames.first
          segment.location = location
          if segment.duration >= config.slow_query_threshold
            txn.record_slow_query(
              key: statement.key, sql: statement.sql, operation: statement.operation, table: statement.table,
              duration: segment.duration, ts: Time.now.to_f - segment.duration / 1000.0, location: location,
              backtrace: frames, raw_sql: payload[:sql], binds: Subscribers.bind_values(payload),
              pool: (payload[:connection].pool if payload[:connection].respond_to?(:pool))
            )
          end
        end
        txn.record_sql(statement, segment.duration, location)
      rescue StandardError => e
        Subscribers.warn(e)
      end
    end

    class PerformJob < Segment
      def initialize
        super(:job) { |p| Names.get("Job", Subscribers.job_name(p), "perform") }
      end

      def start(event, id, payload)
        if Transaction.current
          super
        else
          txn = Transaction.new(type: :job, name: Subscribers.job_name(payload))
          job = payload[:job]
          txn.attributes["queue"] = job.queue_name if job.respond_to?(:queue_name)
          txn.attributes["adapter"] = payload[:adapter].class.name.split("::").last if payload[:adapter]
          txn.attributes["executions"] = job.executions if job.respond_to?(:executions)
          if job.respond_to?(:enqueued_at) && job.enqueued_at
            enqueued = job.enqueued_at.is_a?(String) ? Time.parse(job.enqueued_at).to_f : job.enqueued_at.to_f
            txn.queue_time = ((txn.started_at - enqueued) * 1000.0).clamp(0.0, 86_400_000.0)
          end
          txn.attributes[:__owner] = payload
          Transaction.current = txn
          txn.start_segment("Job/#{txn.name}/perform", :job, payload)
        end
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(event, id, payload)
        txn = Transaction.current
        return unless txn

        if txn.attributes[:__owner].equal?(payload)
          txn.attributes.delete(:__owner)
          txn.error ||= payload[:exception_object] if payload[:exception_object]
          Transaction.current = nil
          txn.finish
          RubyAPM.record(txn)
        else
          super
        end
      rescue StandardError => e
        Subscribers.warn(e)
      end
    end

    VIEW_PREFIX = %r{\A.*?/app/views/}

    # Segment names are built from a handful of parts that repeat on every
    # request; caching them keeps the hot path free of string allocations.
    module Names
      LIMIT = 20_000
      @cache = {}
      @lock = Mutex.new

      module_function

      # Returns the cached name for (a, b, c), building it once with the block.
      def fetch(a, b, c)
        name = @cache[a]&.[](b)&.[](c)
        return name if name

        name = yield.freeze
        @lock.synchronize do
          if (@count = @count.to_i + 1) > LIMIT
            @cache = {}
            @count = 1
          end
          ((@cache[a] ||= {})[b] ||= {})[c] = name
        end
        name
      end

      def get(prefix, subject, op)
        fetch(prefix, subject, op) { "#{prefix}/#{subject}/#{op}" }
      end

      def controller(controller, action)
        fetch(:controller, controller, action) { "Controller/#{controller}##{action}" }
      end

      def view(identifier, kind)
        fetch(:view, identifier, kind) { "View/#{Subscribers.view_name(identifier)}/#{kind}" }
      end
    end

    module_function

    def subscribe!
      return if @subscribed

      n = ActiveSupport::Notifications
      n.subscribe("process_action.action_controller", ProcessAction.new)
      n.subscribe("sql.active_record", Sql.new)
      if RubyAPM.config.instrument_instantiation
        n.subscribe("instantiation.active_record", Segment.new(:activerecord) { |p| Names.get("ActiveRecord", p[:class_name], "instantiate") })
      end
      %w[template partial collection layout].each do |kind|
        n.subscribe("render_#{kind}.action_view", Segment.new(:view) { |p| Names.view(p[:identifier], kind) })
      end
      n.subscribe("perform.active_job", PerformJob.new)
      n.subscribe("enqueue.active_job", Segment.new(:job) { |p| Names.get("Job", job_name(p), "enqueue") })
      %w[read write delete exist? fetch_hit generate read_multi write_multi increment decrement].each do |op|
        n.subscribe("cache_#{op}.active_support", Segment.new(:cache) { |_| "Cache/#{op.delete('?')}" })
      end
      n.subscribe("deliver.action_mailer", Segment.new(:external) { |p| "External/mail/#{p[:mailer]}" })
      @subscribed = true
    end

    def view_name(identifier)
      return "unknown" unless identifier
      identifier.to_s.sub(VIEW_PREFIX, "")
    end

    def job_name(payload)
      job = payload[:job]
      return "UnknownJob" unless job
      job.class.name
    end

    # Stack frames inside the application (not gems, not Ruby itself),
    # innermost first, as "app/models/order.rb:12:in `total'".
    def app_backtrace(limit = 10)
      root = defined?(Rails.root) && Rails.root ? "#{Rails.root}/" : nil
      return [] unless root

      frames = []
      caller_locations(3, 120)&.each do |loc|
        path = loc.absolute_path || loc.path
        next unless path&.start_with?(root)
        next if path.include?("/vendor/") || path.include?("/gems/")
        frames << "#{path.delete_prefix(root)}:#{loc.lineno}:in `#{loc.label}'"
        break if frames.size >= limit
      end
      frames
    end

    def app_location
      app_backtrace(1).first
    end

    # Bind values as the driver received them, kept only in memory so the
    # reporter can EXPLAIN the real statement; never sent to the server.
    def bind_values(payload)
      binds = payload[:type_casted_binds]
      binds = binds.call if binds.respond_to?(:call)
      Array(binds).map { |b| b.respond_to?(:value_for_database) ? b.value_for_database : b }
    rescue StandardError
      []
    end

    def warn(error)
      RubyAPM.config.logger&.warn("[RubyAPM] instrumentation error: #{error.class}: #{error.message}")
    end
  end
end
