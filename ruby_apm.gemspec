require_relative "lib/ruby_apm/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_apm"
  spec.version = RubyAPM::VERSION
  spec.authors = ["RubyAPM"]
  spec.summary = "Rails-specific application performance monitoring agent"
  spec.description = "Instruments controllers, views, ActiveRecord, SQL, jobs, external HTTP and custom code, " \
                     "aggregates in-process and ships compact batches to a RubyAPM server."
  spec.license = "MIT"
  spec.homepage = "https://github.com/christianbpedersen/ruby_apm"
  spec.metadata = { "source_code_uri" => spec.homepage }
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "msgpack", ">= 1.4"
  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake"
end
