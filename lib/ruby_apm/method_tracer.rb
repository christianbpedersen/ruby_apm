module RubyAPM
  # Times individual methods as "Custom/<Class>#<method>" segments.
  #
  #   class PricingService
  #     include RubyAPM::MethodTracer
  #     trace_method :quote
  #     trace_class_method :for_region, name: "Custom/Pricing/region lookup"
  #   end
  module MethodTracer
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def trace_method(*method_names, name: nil, category: :custom)
        method_names.each do |m|
          MethodTracer.wrap(self, m, name || "Custom/#{self.name}##{m}", category)
        end
      end

      def trace_class_method(*method_names, name: nil, category: :custom)
        method_names.each do |m|
          MethodTracer.wrap(singleton_class, m, name || "Custom/#{self.name}.#{m}", category)
        end
      end
    end

    module_function

    # Prepends a module defining a same-named method that opens a segment and
    # calls super. Idempotent per (class, method).
    def wrap(klass, method_name, segment_name, category)
      tracer = (klass.instance_variable_get(:@__ruby_apm_tracer) ||
                klass.instance_variable_set(:@__ruby_apm_tracer, Module.new.tap { |m| klass.prepend(m) }))
      return false if tracer.method_defined?(method_name) || tracer.private_method_defined?(method_name)

      visibility = if klass.private_method_defined?(method_name) then :private
                   elsif klass.protected_method_defined?(method_name) then :protected
                   else :public
                   end
      tracer.define_method(method_name) do |*args, **kwargs, &block|
        txn = Transaction.current
        return super(*args, **kwargs, &block) unless txn

        segment = txn.start_segment(segment_name, category)
        begin
          super(*args, **kwargs, &block)
        ensure
          txn.finish_segment(segment)
        end
      end
      tracer.send(visibility, method_name)
      true
    end

    # Traces every public method defined directly on the classes that live in
    # +dirs+ (e.g. app/services). Constants are derived from file paths the
    # way Zeitwerk does it (app/services/payments/stripe_client.rb ->
    # Payments::StripeClient). Methods inherited from Rails are left alone.
    def auto_instrument(dirs, root)
      count = 0
      Array(dirs).each do |dir|
        base = File.expand_path(dir, root.to_s)
        Dir.glob(File.join(base, "**", "*.rb")).sort.each do |file|
          mod = constant_for(file, base)
          next unless mod.is_a?(Module)
          next if defined?(::ActiveRecord::Base) && mod.is_a?(Class) && mod < ::ActiveRecord::Base

          mod.public_instance_methods(false).each do |m|
            next unless defined_in?(mod.instance_method(m), [base + "/"])
            count += 1 if wrap(mod, m, "Custom/#{mod.name}##{m}", :custom)
          end
          mod.singleton_class.public_instance_methods(false).each do |m|
            next unless defined_in?(mod.method(m), [base + "/"])
            count += 1 if wrap(mod.singleton_class, m, "Custom/#{mod.name}.#{m}", :custom)
          end
        end
      end
      count
    end

    def constant_for(file, base)
      cpath = if defined?(::Rails) && ::Rails.respond_to?(:autoloaders) && ::Rails.autoloaders.main.respond_to?(:cpath_expected_at)
                ::Rails.autoloaders.main.cpath_expected_at(file) rescue nil
              end
      cpath ||= begin
        require "active_support/inflector"
        ActiveSupport::Inflector.camelize(file.delete_prefix("#{base}/").delete_suffix(".rb"))
      end
      Object.const_get(cpath) if cpath
    rescue StandardError
      nil
    end

    def defined_in?(method, dirs)
      file = method.source_location&.first
      file && dirs.any? { |d| file.start_with?(d) }
    end
  end
end
