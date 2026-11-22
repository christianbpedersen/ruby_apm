require "test_helper"
require "tmpdir"

class AutoInstrumentTest < RubyAPMTest
  def test_wraps_public_methods_of_classes_defined_under_the_paths
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/services"))
      File.write(File.join(root, "app/services/tax_calculator.rb"), <<~RUBY)
        class TaxCalculator
          def self.rate_for(country) = country == "DK" ? 0.25 : 0.1
          def total(amount) = amount + vat(amount)
          def vat(amount) = (amount * 0.25).round(2)
          private
          def secret = 42
        end
      RUBY
      load File.join(root, "app/services/tax_calculator.rb")

      count = RubyAPM::MethodTracer.auto_instrument(["app/services"], root)
      assert_equal 3, count # total, vat, .rate_for; private methods are left alone

      run_request(lambda do |_|
        RubyAPM.set_transaction_name("Tax#show")
        assert_equal 125.0, TaxCalculator.new.total(100)
        assert_equal 0.25, TaxCalculator.rate_for("DK")
        [200, {}, []]
      end)
      bucket, = drained
      names = bucket.transactions[[:web, "Tax#show"]].segments.keys
      assert_includes names, "Custom/TaxCalculator#total"
      assert_includes names, "Custom/TaxCalculator#vat"
      assert_includes names, "Custom/TaxCalculator.rate_for"
      assert_equal 0, RubyAPM::MethodTracer.auto_instrument(["app/services"], root), "idempotent"
    end
  end
end
