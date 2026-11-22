require "test_helper"

class TransactionTest < RubyAPMTest
  def test_exclusive_time_and_breakdown
    txn = RubyAPM::Transaction.new(type: :web, name: "A#b")
    RubyAPM::Transaction.current = txn
    RubyAPM.trace("Custom/outer") do
      sleep 0.02
      RubyAPM.trace("Custom/inner") { sleep 0.03 }
    end
    RubyAPM::Transaction.current = nil
    txn.finish

    outer = txn.segments["Custom/outer"]
    inner = txn.segments["Custom/inner"]
    assert_operator inner.total, :>=, 30
    assert_operator outer.exclusive, :>=, 20
    assert_in_delta outer.total - inner.total, outer.exclusive, 0.01
    assert_in_delta inner.total, inner.exclusive, 0.01
    assert_in_delta txn.duration, txn.breakdown.values.sum, 0.5
    tree = txn.trace_wire
    assert_equal "Custom/outer", tree[4][0][0]
    assert_equal "Custom/inner", tree[4][0][4][0][0]
  end

  def test_unclosed_segments_are_closed_by_outer_finish
    txn = RubyAPM::Transaction.new(type: :web, name: "A#b")
    outer = Object.new
    txn.start_segment("Custom/outer", :custom, outer)
    txn.start_segment("Custom/leaked", :custom, Object.new)
    txn.finish_segment(outer)
    txn.finish
    assert_equal 1, txn.segments["Custom/leaked"].count
    assert_equal 1, txn.segments["Custom/outer"].count
  end

  def test_trace_tree_is_capped_but_metrics_are_complete
    RubyAPM.config.max_segments_per_trace = 5
    txn = RubyAPM::Transaction.new(type: :web, name: "A#b")
    RubyAPM::Transaction.current = txn
    20.times { RubyAPM.trace("Custom/x") {} }
    RubyAPM::Transaction.current = nil
    txn.finish
    assert_equal 20, txn.segments["Custom/x"].count
    assert_equal 5, txn.trace_wire[4].size
  ensure
    RubyAPM.config.max_segments_per_trace = 1500
  end
end
