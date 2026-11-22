require "shellwords"

module RubyAPM
  class Config
    # Where the RubyAPM server lives and how this app identifies itself.
    attr_accessor :endpoint, :api_key, :app_name, :environment, :host

    # Master switch. Defaults to on when an api_key is present.
    attr_accessor :enabled

    # How often the background reporter ships aggregated data (seconds).
    attr_accessor :flush_interval

    # Apdex threshold in milliseconds (satisfied <= T, tolerating <= 4T).
    attr_accessor :apdex_t

    # Transactions slower than this (ms) are candidates for a full trace.
    attr_accessor :trace_threshold
    # Maximum number of traces shipped per flush, and segments kept per trace.
    attr_accessor :max_traces_per_flush, :max_segments_per_trace

    # SQL slower than this (ms) records the app frame that issued it.
    attr_accessor :sql_backtrace_threshold
    # Identical SQL executed at least this many times in one request is flagged as N+1.
    attr_accessor :n_plus_one_threshold

    # Individual executions at least this slow (ms) are sampled with their
    # backtrace, and SELECTs get an EXPLAIN plan from the reporter thread.
    attr_accessor :slow_query_threshold, :explain_slow_queries, :max_slow_queries_per_flush

    # GraphQL fields faster than this (ms) are counted but left out of trace trees.
    attr_accessor :graphql_field_trace_threshold

    # Separate "instantiate" segments for building model objects. That time is
    # already inside the ActiveRecord segments; enabling this only splits it
    # out, at the cost of one more event per query.
    attr_accessor :instrument_instantiation

    # Cardinality guards so a buggy naming scheme cannot blow up memory.
    attr_accessor :max_transaction_names, :max_sql_statements

    # Exceptions that are expected control flow (404s, bad tokens), not errors.
    attr_accessor :ignored_errors

    # Requests whose path matches are not recorded.
    attr_accessor :ignore_paths

    # Directories (relative to Rails.root) whose classes get every public method traced.
    attr_accessor :auto_instrument_paths

    # Network timeouts for the reporter (seconds).
    attr_accessor :open_timeout, :read_timeout

    attr_accessor :logger

    # Code revision of this deploy; the server marks the time each new
    # revision first reports as a deployment on every chart.
    attr_writer :revision

    def revision
      @revision ||= detect_revision
    end

    # Reads RUBY_APM_<name>, falling back to the pre-rename NEW_FENIC_<name>.
    def self.env(name)
      [ENV["RUBY_APM_#{name}"], ENV["NEW_FENIC_#{name}"]].find { |v| v && !v.empty? }
    end

    def initialize
      @endpoint = self.class.env("ENDPOINT") || "http://localhost:4400"
      @api_key = self.class.env("API_KEY")
      @app_name = self.class.env("APP_NAME")
      @environment = self.class.env("ENV") || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      @host = Socket.gethostname rescue "unknown"
      @enabled = nil
      @flush_interval = Float(self.class.env("FLUSH_INTERVAL") || 10)
      @apdex_t = 500.0
      @trace_threshold = 300.0
      @max_traces_per_flush = 20
      @max_segments_per_trace = 1500
      @sql_backtrace_threshold = 10.0
      @n_plus_one_threshold = 10
      @slow_query_threshold = 100.0
      @explain_slow_queries = true
      @max_slow_queries_per_flush = 50
      @graphql_field_trace_threshold = 1.0
      @instrument_instantiation = false
      @max_transaction_names = 2_000
      @max_sql_statements = 5_000
      @ignored_errors = %w[ActiveRecord::RecordNotFound ActionController::RoutingError ActionController::UnknownFormat
                           ActionController::InvalidAuthenticityToken ActionController::BadRequest ActionController::ParameterMissing
                           AbstractController::ActionNotFound]
      @ignore_paths = [%r{\A/assets/}, %r{\A/up\z}, %r{\A/favicon}]
      @auto_instrument_paths = []
      @open_timeout = 2
      @read_timeout = 5
      @logger = nil
    end

    def enabled?
      return @enabled unless @enabled.nil?
      !api_key.to_s.empty?
    end

    def detect_revision
      env = self.class.env("REVISION") || ENV["GIT_REV"] || ENV["HEROKU_SLUG_COMMIT"] || ENV["RENDER_GIT_COMMIT"]
      return env if env && !env.empty?

      root = defined?(Rails.root) && Rails.root ? Rails.root.to_s : Dir.pwd
      file = File.join(root, "REVISION")
      return File.read(file).strip if File.exist?(file)

      sha = `git -C #{root.shellescape} rev-parse --short HEAD 2>/dev/null`.strip
      sha.empty? ? nil : sha
    rescue StandardError
      nil
    end

    def ignored_error?(error)
      return false unless error.is_a?(Exception)
      error.class.ancestors.any? { |a| a.is_a?(Class) && ignored_errors.include?(a.name) }
    end

    def ignored_path?(path)
      ignore_paths.any? { |pattern| pattern.is_a?(Regexp) ? pattern.match?(path) : path == pattern }
    end
  end
end
