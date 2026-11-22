require "net/http"
require "uri"
require "zlib"
require "stringio"
require "msgpack"
require "securerandom"

module RubyAPM
  # Background thread that periodically drains the aggregator and POSTs one
  # gzipped MessagePack document to the server. Restarts itself after fork
  # (Puma cluster, Unicorn, Sidekiq swarm) because threads do not survive it.
  class Reporter
    PROTOCOL_VERSION = 1

    attr_reader :aggregator, :stats

    def initialize(config, aggregator)
      @config = config
      @aggregator = aggregator
      @mutex = Mutex.new
      @thread = nil
      @pid = nil
      @http = nil
      @stats = { flushes: 0, failures: 0, bytes: 0, last_error: nil }
      @explainer = Explainer.new(config)
      @runtime = RuntimeSampler.new
    end

    def ensure_running
      return if @pid == Process.pid && @thread&.alive?

      @mutex.synchronize do
        return if @pid == Process.pid && @thread&.alive?

        if @pid && @pid != Process.pid
          # Forked child: drop the parent's half-built state and connection.
          @aggregator.drain
          @aggregator.take_slow_queries
          @aggregator.take_pending
          @http = nil
          @runtime = RuntimeSampler.new
        end
        @pid = Process.pid
        @thread = Thread.new { run }
        @thread.name = "ruby_apm-reporter" if @thread.respond_to?(:name=)
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    def stop
      thread = @thread
      @thread = nil
      thread&.kill
      flush
    end

    def flush
      buckets, traces = @aggregator.drain
      slow = @aggregator.take_slow_queries
      runtime = @runtime.sample
      wire_buckets = @aggregator.take_pending + buckets.map { |minute, bucket| bucket_to_wire(minute, bucket) }
      return true if wire_buckets.empty? && traces.empty? && slow.empty? && runtime.nil?

      @explainer.explain(slow)
      body = begin
        encode(payload(wire_buckets, traces, slow_queries_to_wire(slow), runtime))
      rescue StandardError => e
        # Something in a trace or sample could not be serialized; ship the
        # metrics without them rather than lose the whole flush.
        log(:warn, "dropping traces from flush: #{e.class}: #{e.message}")
        encode(payload(wire_buckets, [], [], runtime))
      end
      if post(body)
        @stats[:flushes] += 1
        @stats[:bytes] += body.bytesize
        true
      else
        @stats[:failures] += 1
        @aggregator.restore(wire_buckets)
        false
      end
    rescue StandardError => e
      @stats[:failures] += 1
      @stats[:last_error] = "#{e.class}: #{e.message}"
      log(:warn, "flush failed: #{e.class}: #{e.message}")
      @aggregator.restore(wire_buckets) if wire_buckets && !wire_buckets.empty?
      false
    end

    def payload(wire_buckets, traces, slow_queries = [], runtime = nil)
      {
        "v" => PROTOCOL_VERSION, "agent" => VERSION, "app" => @config.app_name, "env" => @config.environment,
        "host" => @config.host, "pid" => Process.pid, "sent_at" => Time.now.to_f.round(3),
        "rails" => (defined?(Rails.version) ? Rails.version : nil), "ruby" => RUBY_VERSION,
        "apdex_t" => @config.apdex_t, "revision" => @config.revision, "booted_at" => RubyAPM.booted_at,
        "buckets" => wire_buckets, "traces" => traces,
        "slow_queries" => slow_queries, "runtime" => runtime
      }
    end

    def encode(doc)
      io = StringIO.new
      io.set_encoding(Encoding::BINARY)
      gz = Zlib::GzipWriter.new(io, Zlib::BEST_SPEED)
      gz.write(MessagePack.pack(doc))
      gz.close
      io.string
    end

    private

    def run
      loop do
        sleep @config.flush_interval
        flush
      end
    rescue StandardError => e
      log(:error, "reporter thread died: #{e.class}: #{e.message}")
    end

    def bucket_to_wire(minute, bucket)
      {
        # Stable across retries: the server ignores a bucket id it has already
        # stored, so a retry after a timed-out-but-committed POST cannot double count.
        "id" => SecureRandom.uuid,
        "ts" => minute,
        "transactions" => bucket.transactions.map { |(type, name), stat| stat.to_wire(type, name) },
        "sql" => bucket.sql.map { |(type, name, _), agg| agg.to_wire(type, name) },
        "errors" => bucket.errors.values
      }
    end

    # Raw SQL and bind values stay in this process; only the obfuscated form ships.
    def slow_queries_to_wire(samples)
      samples.map do |q|
        { "tx_type" => q[:tx_type], "tx" => q[:tx], "uri" => q[:uri], "key" => q[:key], "sql" => q[:sql],
          "op" => q[:operation], "table" => q[:table], "duration" => q[:duration].round(3), "ts" => q[:ts].round(3),
          "location" => q[:location], "backtrace" => q[:backtrace], "explain" => q[:explain] }
      end
    end

    def post(body)
      uri = ingest_uri
      http = connection(uri)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/msgpack"
      request["Content-Encoding"] = "gzip"
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["User-Agent"] = "ruby_apm-ruby/#{VERSION}"
      request.body = body
      response = http.request(request)
      return true if response.is_a?(Net::HTTPSuccess)

      @stats[:last_error] = "HTTP #{response.code}"
      log(:warn, "server rejected payload: HTTP #{response.code} #{response.body.to_s[0, 200]}")
      # 4xx other than 429 means the payload itself is bad; retrying will not help.
      code = response.code.to_i
      code.between?(400, 499) && code != 429
    rescue StandardError => e
      @http = nil
      @stats[:last_error] = "#{e.class}: #{e.message}"
      log(:warn, "could not reach #{@config.endpoint}: #{e.class}: #{e.message}")
      false
    end

    # Appends to the endpoint's path, so a server mounted under a prefix
    # (https://host/apm) receives /apm/api/v1/ingest.
    def ingest_uri
      @ingest_uri ||= begin
        base = URI(@config.endpoint.to_s)
        base.path = "#{base.path.chomp('/')}/api/v1/ingest"
        base
      end
    end

    def connection(uri)
      return @http if @http&.started?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http.write_timeout = @config.read_timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30
      http.start
      @http = http
    end

    def log(level, message)
      @config.logger&.public_send(level, "[RubyAPM] #{message}")
    end
  end
end
