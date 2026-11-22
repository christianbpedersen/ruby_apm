require "socket"
require "set"
require "ruby_apm/version"
require "ruby_apm/config"
require "ruby_apm/histogram"
require "ruby_apm/sql_obfuscator"
require "ruby_apm/transaction"
require "ruby_apm/aggregator"
require "ruby_apm/explainer"
require "ruby_apm/runtime_sampler"
require "ruby_apm/reporter"
require "ruby_apm/middleware"
require "ruby_apm/subscribers"
require "ruby_apm/method_tracer"

module RubyAPM
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
      config
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end

    def aggregator
      @aggregator ||= Aggregator.new(config)
    end

    def reporter
      @reporter ||= Reporter.new(config, aggregator)
    end

    def booted_at
      @booted_at ||= Time.now.to_f.round(3)
    end

    def started?
      @started == true
    end

    # Wires up instrumentation. Called by the Railtie after initializers run;
    # call it yourself in a non-Rails Rack app.
    def start!
      return false unless config.enabled?
      return true if started?

      booted_at
      config.revision
      Subscribers.subscribe!
      require "ruby_apm/instrumentation/active_record"
      Instrumentation::ActiveRecord.install!
      require "ruby_apm/instrumentation/net_http"
      Instrumentation::NetHttp.install!
      require "ruby_apm/instrumentation/graphql"
      Instrumentation::GraphQL.install!
      if defined?(::Sidekiq)
        require "ruby_apm/instrumentation/sidekiq"
        Instrumentation::Sidekiq.install!
      end
      at_exit { reporter.stop }
      @started = true
    end

    def current_transaction
      Transaction.current
    end

    # Starts a transaction for work outside a request or job (rake tasks,
    # scripts, consumers). Nested calls become segments of the outer one.
    def in_transaction(name, type: :job)
      if Transaction.current
        return trace(name) { yield }
      end

      txn = Transaction.new(type: type, name: name)
      Transaction.current = txn
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        txn.error = e
        raise
      ensure
        Transaction.current = nil
        txn.finish
        record(txn)
      end
    end

    # Times a block as a segment of the current transaction. A no-op outside one.
    def trace(name, category: :custom)
      txn = Transaction.current
      return yield unless txn

      segment = txn.start_segment(name, category)
      begin
        yield
      ensure
        txn.finish_segment(segment)
      end
    end

    # Name the current transaction explicitly (e.g. for Rack endpoints or GraphQL operations).
    def set_transaction_name(name)
      txn = Transaction.current
      txn.name = name if txn
    end

    # Values must survive MessagePack; anything else is stored as its string form.
    def add_attribute(key, value)
      txn = Transaction.current
      return unless txn

      value = value.to_s[0, 1_000] unless value.nil? || value == true || value == false ||
                                         value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(String)
      value = value[0, 1_000] if value.is_a?(String)
      txn.attributes[key.to_s[0, 100]] = value
    end

    def notice_error(error)
      txn = Transaction.current
      txn.error ||= error if txn
    end

    def ignore_transaction!
      txn = Transaction.current
      txn.ignored = true if txn
    end

    def record(txn)
      return unless started?

      # Start (or, in a freshly forked worker, reset) the reporter first, so
      # resetting inherited state cannot discard this transaction.
      reporter.ensure_running
      aggregator.record(txn)
    rescue StandardError => e
      config.logger&.warn("[RubyAPM] could not record transaction: #{e.class}: #{e.message}")
    end

    # Test helper: forget all state.
    def reset!
      @aggregator = nil
      @reporter = nil
      @config = nil
      @started = false
      Transaction.current = nil
    end
  end
end

# Pre-rename name, so existing `NewFenic.configure` initializers keep working.
NewFenic = RubyAPM unless defined?(NewFenic)

require "ruby_apm/railtie" if defined?(Rails::Railtie)
