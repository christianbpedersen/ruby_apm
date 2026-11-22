module RubyAPM
  # Geometric latency histogram shared by agent and server: bucket i holds
  # durations in (BASE**(i-1), BASE**i] milliseconds, bucket 0 holds <= 1ms.
  # 56 buckets reach ~ 200s, which is plenty for request latency.
  module Histogram
    BASE = 1.25
    SIZE = 56
    LOG_BASE = Math.log(BASE)

    module_function

    def index(ms)
      return 0 if ms <= 1.0
      i = (Math.log(ms) / LOG_BASE).ceil
      i >= SIZE ? SIZE - 1 : i
    end

    def upper_bound(i)
      BASE**i
    end
  end
end
