require "test_helper"
require "sidekiq"
require "ruby_apm/instrumentation/sidekiq"

class SidekiqTest < RubyAPMTest
  def server = RubyAPM::Instrumentation::Sidekiq::ServerMiddleware.new

  def test_job_transaction_with_queue_time_and_db
    job = { "class" => "HardWorker", "jid" => "abc", "enqueued_at" => ((Time.now.to_f - 2) * 1000).to_i }
    server.call(Object.new, job, "critical") { Widget.count }
    bucket, = drained
    stat = bucket.transactions[[:job, "HardWorker"]]
    assert_equal 1, stat.count
    assert_in_delta 2000, stat.queue_time, 200
    assert stat.segments.key?("Job/HardWorker/perform")
    assert stat.segments.key?("ActiveRecord/Widget/count")
  end

  def test_wrapped_activejob_name_and_errors
    job = { "class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "ImportJob", "jid" => "x", "enqueued_at" => Time.now.to_f - 1 }
    assert_raises(RuntimeError) { server.call(Object.new, job, "default") { raise "boom" } }
    bucket, = drained
    assert_equal 1, bucket.transactions[[:job, "ImportJob"]].errors
    assert_in_delta 1000, bucket.transactions[[:job, "ImportJob"]].queue_time, 200
  end

  def test_client_middleware_times_enqueue_inside_a_request
    client = RubyAPM::Instrumentation::Sidekiq::ClientMiddleware.new
    run_request(->(_) { RubyAPM.set_transaction_name("Orders#create"); client.call("Mailer", { "class" => "Mailer" }, "q", nil) { true }; [200, {}, []] })
    bucket, = drained
    assert bucket.transactions[[:web, "Orders#create"]].segments.key?("Job/Mailer/enqueue")
  end

  def test_middleware_is_registered
    RubyAPM::Instrumentation::Sidekiq.install!
    chain = Sidekiq.default_configuration.client_middleware
    assert chain.exists?(RubyAPM::Instrumentation::Sidekiq::ClientMiddleware)
  end
end
