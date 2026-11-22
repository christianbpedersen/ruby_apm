require "test_helper"

class HistogramTest < Minitest::Test
  def test_bucket_bounds
    assert_equal 0, RubyAPM::Histogram.index(0.2)
    [1.5, 10, 123.4, 999, 5000].each do |ms|
      i = RubyAPM::Histogram.index(ms)
      assert_operator ms, :<=, RubyAPM::Histogram.upper_bound(i)
      assert_operator ms, :>, RubyAPM::Histogram.upper_bound(i - 1)
    end
    assert_equal RubyAPM::Histogram::SIZE - 1, RubyAPM::Histogram.index(10**9)
  end
end
