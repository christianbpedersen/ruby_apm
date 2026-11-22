module RubyAPM
  # Outermost middleware: opens the web transaction so middleware time, routing
  # and controller work are all measured, and records exceptions escaping Rails.
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # The Railtie inserts this middleware in every environment; it does
      # nothing unless the agent actually started (enabled with an API key).
      return @app.call(env) unless RubyAPM.started?
      return @app.call(env) if Transaction.current || RubyAPM.config.ignored_path?(env["PATH_INFO"].to_s)

      txn = Transaction.new(type: :web, uri: env["PATH_INFO"])
      txn.queue_time = queue_time(env, txn.started_at)
      Transaction.current = txn
      status = nil
      begin
        status, headers, body = @app.call(env)
        [status, headers, body]
      rescue Exception => e # rubocop:disable Lint/RescueException
        txn.error ||= e
        status = 500
        raise
      ensure
        Transaction.current = nil
        txn.status ||= status.to_i if status
        txn.name ||= fallback_name(env, txn.status)
        txn.finish
        RubyAPM.record(txn)
      end
    end

    private

    # Rack apps that are not Rails controllers (mounted engines, Sinatra, 404s).
    def fallback_name(env, status)
      return "Rack/404" if status == 404
      "Rack/#{env['REQUEST_METHOD']}"
    end

    # Time between the load balancer accepting the request and Ruby picking it
    # up, from X-Request-Start ("t=<seconds|ms|us>" as set by nginx/Heroku).
    def queue_time(env, now)
      raw = env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"]
      return 0.0 unless raw

      value = raw.to_s.delete_prefix("t=").to_f
      return 0.0 if value <= 0

      seconds = if value > 1e15 then value / 1e6
                elsif value > 1e12 then value / 1e3
                else value
                end
      queued = (now - seconds) * 1000.0
      queued.positive? && queued < 60_000 ? queued : 0.0
    end
  end
end
