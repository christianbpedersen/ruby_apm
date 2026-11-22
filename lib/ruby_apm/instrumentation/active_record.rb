module RubyAPM
  module Instrumentation
    # Measures ActiveRecord as a whole (relation building, Arel compilation,
    # preloading, type casting, callbacks) around the SQL Rails already reports.
    # The exclusive time of these segments is "ActiveRecord overhead"; their
    # SQL children are "Database" time.
    module ActiveRecord
      module RelationLoad
        def exec_queries(&block)
          ActiveRecord.wrap(model_name_for_trace, "load") { super }
        end

        def calculate(operation, *args, **kwargs)
          ActiveRecord.wrap(model_name_for_trace, operation.to_s) { super }
        end

        def pluck(*args)
          ActiveRecord.wrap(model_name_for_trace, "pluck") { super }
        end

        def update_all(*args)
          ActiveRecord.wrap(model_name_for_trace, "update_all") { super }
        end

        def delete_all(*args)
          ActiveRecord.wrap(model_name_for_trace, "delete_all") { super }
        end

        private

        def model_name_for_trace
          (respond_to?(:model) ? model : klass).name
        end
      end

      module Querying
        def find_by_sql(*args, **kwargs, &block)
          ActiveRecord.wrap(name, "find") { super }
        end
      end

      module Persistence
        def save(*args, **kwargs, &block)
          ActiveRecord.wrap(self.class.name, "save") { super }
        end

        def save!(*args, **kwargs, &block)
          ActiveRecord.wrap(self.class.name, "save") { super }
        end

        def destroy
          ActiveRecord.wrap(self.class.name, "destroy") { super }
        end
      end

      module_function

      def install!
        return if @installed
        return unless defined?(::ActiveRecord::Base)

        ::ActiveSupport.on_load(:active_record) do
          ::ActiveRecord::Relation.prepend(RelationLoad)
          ::ActiveRecord::Base.singleton_class.prepend(Querying)
          ::ActiveRecord::Base.prepend(Persistence)
        end
        @installed = true
      end

      # Nested AR calls (a load that triggers preloads, save that loads an
      # association) are flattened into the outermost one, so overhead is
      # counted once and the trace stays readable.
      def wrap(model, op, &block)
        txn = Transaction.current
        return yield if txn.nil? || txn.current_segment.category == :activerecord

        segment = txn.start_segment(Subscribers::Names.get("ActiveRecord", model, op), :activerecord)
        begin
          yield
        ensure
          txn.finish_segment(segment)
        end
      end
    end
  end
end
