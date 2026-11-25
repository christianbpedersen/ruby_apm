require_relative "test_helper"

# Regressions for the November 2026 security review: nothing that looks like
# customer data, credentials or secrets leaves the process.
class SecurityTest < RubyAPMTest
  def test_plans_keep_estimates_and_drop_values_on_every_line
    plan = <<~PLAN
      Sort  (cost=10.0..10.5 rows=200 width=40)
        Sort Key: (similarity(name, 'alice smith'::text)) DESC
        Sort Method: external merge  Disk: 1234kB
        ->  Seq Scan on orders  (cost=0.00..1834.00 rows=50000 width=64)
              Filter: (status = 'open'::text)
              Group Key: CASE WHEN (ssn = '123-45-6789'::text) THEN 1 ELSE 0 END
              Filter: (amount > 1e+20)
    PLAN
    out = RubyAPM::Explainer.new(RubyAPM.config).obfuscate_plan(plan)
    refute_match(/alice|123-45|open'|1e\+20/, out)
    assert_includes out, "(cost=0.00..1834.00 rows=50000 width=64)"
    assert_includes out, "Sort Method: external merge  Disk: 1234kB"
    assert_includes out, "Seq Scan on orders"
  end

  class FakeDbError < StandardError
    def self.ancestors = [self, Class.new { def self.name = "ActiveRecord::StatementInvalid" }, StandardError]
  end

  def test_database_error_messages_are_scrubbed
    err = FakeDbError.new(%(PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "users_email"\nDETAIL:  Key (email)=(alice@example.com) already exists.\n: INSERT INTO users (email) VALUES ('alice@example.com')))
    msg = RubyAPM::Redact.error_message(err, RubyAPM.config)
    refute_includes msg, "alice@example.com"
    assert_includes msg, "duplicate key value"
  end

  def test_error_message_filter_hook
    RubyAPM.config.error_message_filter = ->(m, _) { m.gsub(/\d{4}-\d{4}/, "[card]") }
    assert_equal "charge [card] failed", RubyAPM::Redact.error_message(RuntimeError.new("charge 4242-4242 failed"), RubyAPM.config)
  ensure
    RubyAPM.config.error_message_filter = nil
  end

  def test_paths_lose_tokens_but_keep_routes
    assert_equal "/password/:redacted", RubyAPM::Redact.path("/password/eyJfcmFpbHMiOnsiZGF0YSI6WzEsIjdlMmQyYz--0e541c076cd1e926")
    assert_equal "/rails/active_storage/blobs/redirect/:redacted/report.pdf", RubyAPM::Redact.path("/rails/active_storage/blobs/redirect/eyJfcmFpbHMiOnsiZGF0YSI6MTIzfQ==--abc123def/report.pdf")
    assert_equal "/apps/42/transactions", RubyAPM::Redact.path("/apps/42/transactions")
    assert_equal "/services/:redacted/:redacted/:redacted", RubyAPM::Redact.outbound_path("/services/T0001/B0002/XyZsecretsecret")
    assert_equal "/v1/charges/:id", RubyAPM::Redact.outbound_path("/v1/charges/123")
  end

  def test_graphql_operation_names_are_validated
    query = Struct.new(:selected_operation_name)
    assert_equal "CheckoutPage", RubyAPM::Instrumentation::GraphQL.operation_name(query.new("CheckoutPage"))
    assert_equal "<invalid>", RubyAPM::Instrumentation::GraphQL.operation_name(query.new("x" * 5_000))
    assert_equal "<invalid>", RubyAPM::Instrumentation::GraphQL.operation_name(query.new("a b; drop"))
  end

  def test_api_key_never_appears_in_inspect
    RubyAPM.config.api_key = "nf_supersecret"
    refute_includes RubyAPM.config.inspect, "nf_supersecret"
    refute_includes RubyAPM.reporter.inspect, "nf_supersecret"
  ensure
    RubyAPM.config.api_key = "test"
  end
end
