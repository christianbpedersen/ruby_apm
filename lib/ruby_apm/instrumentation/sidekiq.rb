module RubyAPM
  module Instrumentation
    # Native Sidekiq workers (ActiveJob on Sidekiq is named after the wrapped
    # job class, so both report as the same transaction).
    module Sidekiq
      class ServerMiddleware
        include ::Sidekiq::ServerMiddleware if defined?(::Sidekiq::ServerMiddleware)

        def call(_worker, job, queue)
          return yield if Transaction.current

          txn = Transaction.new(type: :job, name: Sidekiq.job_name(job))
          txn.attributes["queue"] = queue
          txn.attributes["jid"] = job["jid"]
          txn.attributes["retry_count"] = job["retry_count"] if job["retry_count"]
          txn.attributes["adapter"] = "Sidekiq"
          txn.queue_time = Sidekiq.queue_time(job, txn.started_at)
          Transaction.current = txn
          segment = txn.start_segment(Subscribers::Names.get("Job", txn.name, "perform"), :job)
          begin
            yield
          rescue Exception => e # rubocop:disable Lint/RescueException
            txn.error = e
            raise
          ensure
            txn.finish_segment(segment)
            Transaction.current = nil
            txn.finish
            RubyAPM.record(txn)
          end
        end
      end

      class ClientMiddleware
        include ::Sidekiq::ClientMiddleware if defined?(::Sidekiq::ClientMiddleware)

        def call(_worker_class, job, _queue, _redis_pool)
          txn = Transaction.current
          return yield unless txn

          segment = txn.start_segment(Subscribers::Names.get("Job", Sidekiq.job_name(job), "enqueue"), :job)
          begin
            yield
          ensure
            txn.finish_segment(segment)
          end
        end
      end

      module_function

      def job_name(job)
        (job["wrapped"] || job["class"]).to_s
      end

      # enqueued_at is epoch seconds (float) in Sidekiq < 8, epoch ms (int) in 8+.
      def queue_time(job, now)
        at = job["enqueued_at"]
        return 0.0 unless at.is_a?(Numeric) && at.positive?

        seconds = at > 1e11 ? at / 1000.0 : at.to_f
        ((now - seconds) * 1000.0).clamp(0.0, 86_400_000.0)
      end

      def install!
        return if @installed
        return unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)

        ::Sidekiq.configure_server do |config|
          config.server_middleware { |chain| chain.prepend(ServerMiddleware) }
          config.client_middleware { |chain| chain.add(ClientMiddleware) }
        end
        ::Sidekiq.configure_client do |config|
          config.client_middleware { |chain| chain.add(ClientMiddleware) }
        end
        @installed = true
      end
    end
  end
end
