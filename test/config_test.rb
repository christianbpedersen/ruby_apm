require_relative "test_helper"

class ConfigTest < Minitest::Test
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def test_reads_ruby_apm_variables
    with_env("RUBY_APM_API_KEY" => "new", "NEW_FENIC_API_KEY" => "old") do
      assert_equal "new", RubyAPM::Config.new.api_key
    end
  end

  def test_falls_back_to_new_fenic_variables
    with_env("RUBY_APM_API_KEY" => nil, "NEW_FENIC_API_KEY" => "old", "RUBY_APM_ENDPOINT" => "", "NEW_FENIC_ENDPOINT" => "https://old.example") do
      config = RubyAPM::Config.new
      assert_equal "old", config.api_key
      assert_equal "https://old.example", config.endpoint
    end
  end

  def test_new_fenic_alias
    assert_same RubyAPM, NewFenic
  end
end
