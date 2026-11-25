module RubyAPM
  class Railtie < ::Rails::Railtie
    config.ruby_apm = ActiveSupport::OrderedOptions.new

    initializer "ruby_apm.middleware" do |app|
      app.middleware.insert(0, RubyAPM::Middleware)
    end

    initializer "ruby_apm.configure", after: :load_config_initializers do |app|
      c = RubyAPM.config
      c.app_name ||= app.class.module_parent_name
      c.logger ||= Rails.logger
      app.config.ruby_apm.each { |k, v| c.public_send("#{k}=", v) if c.respond_to?("#{k}=") }
    end

    config.after_initialize do |app|
      # MySQL quoting rules differ (backslash escapes, "..." strings, # comments).
      if defined?(::ActiveRecord::Base)
        adapter = (::ActiveRecord::Base.connection_db_config&.adapter rescue nil).to_s
        RubyAPM::SqlObfuscator.mysql = adapter.match?(/mysql|trilogy/i)
      end
      if RubyAPM.start!
        require "ruby_apm/error_subscriber"
        Rails.error.subscribe(RubyAPM::ErrorSubscriber.new) if Rails.respond_to?(:error) && Rails.error.respond_to?(:subscribe)
        unless RubyAPM.config.auto_instrument_paths.empty?
          # Classes must be loaded before their methods can be wrapped.
          Rails.application.eager_load! unless app.config.eager_load
          n = MethodTracer.auto_instrument(RubyAPM.config.auto_instrument_paths, Rails.root)
          RubyAPM.config.logger&.info("[RubyAPM] auto-instrumented #{n} methods")
        end
        RubyAPM.config.logger&.info("[RubyAPM] reporting #{RubyAPM.config.app_name} to #{RubyAPM.config.safe_endpoint}")
      end
    end
  end
end
