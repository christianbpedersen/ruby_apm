$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "active_record"
require "rack"
require "ruby_apm"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :widgets do |t|
    t.string :name
    t.integer :price
  end
end

class Widget < ActiveRecord::Base; end

RubyAPM.config.enabled = true
RubyAPM.config.api_key = "test"
RubyAPM.config.app_name = "Test"
RubyAPM.start!

class RubyAPMTest < Minitest::Test
  def setup
    RubyAPM.aggregator.drain
    RubyAPM.aggregator.take_pending
  end

  def run_request(app, path = "/widgets")
    RubyAPM::Middleware.new(app).call(Rack::MockRequest.env_for(path))
  end

  def drained
    buckets, traces = RubyAPM.aggregator.drain
    [buckets.values.first, traces]
  end
end
