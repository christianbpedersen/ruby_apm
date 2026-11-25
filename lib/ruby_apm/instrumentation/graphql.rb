module RubyAPM
  module Instrumentation
    # graphql-ruby tracer. Without it every request is "GraphqlController#execute";
    # with it transactions are named after the operation and resolver time is
    # its own "graphql" layer, broken down per field.
    #
    # Installed automatically into every GraphQL::Schema subclass at boot, or
    # by hand:
    #
    #   class AppSchema < GraphQL::Schema
    #     trace_with RubyAPM::Instrumentation::GraphQL::Trace
    #   end
    #
    # Leaf (scalar/enum) fields are not traced unless they opt in with
    # `field :total, trace: true` or the schema passes `trace_scalars: true`.
    module GraphQL
      module Trace
        def initialize(trace_scalars: false, set_transaction_name: true, **rest)
          @nf_trace_scalars = trace_scalars
          @nf_set_name = set_transaction_name
          @nf_field_names = {}
          super(**rest)
        end

        def lex(query_string:)
          GraphQL.segment("GraphQL/lex") { super }
        end

        def parse(query_string:)
          GraphQL.segment("GraphQL/parse") { super }
        end

        def validate(query:, validate:)
          GraphQL.segment("GraphQL/validate") { super }
        end

        def analyze_multiplex(multiplex:)
          GraphQL.segment("GraphQL/analyze") { super }
        end

        def execute_multiplex(multiplex:)
          txn = Transaction.current
          if txn
            name_transaction(txn, multiplex.queries)
          else
            # GraphQL executed outside a request/job (e.g. a test or a script).
            return RubyAPM.in_transaction(GraphQL.transaction_name(multiplex.queries), type: :job) { super }
          end
          GraphQL.segment("GraphQL/execute") { super }
        end

        def execute_field(field:, query:, ast_node:, arguments:, object:)
          name = traced_field_name(field)
          return super unless name

          GraphQL.segment(name, prune: true) { super }
        end

        def execute_field_lazy(field:, query:, ast_node:, arguments:, object:)
          name = traced_field_name(field)
          return super unless name

          GraphQL.segment(name, prune: true) { super }
        end

        def begin_dataloader_source(source)
          txn = Transaction.current
          txn&.start_segment("GraphQL/Source/#{source.class.name}", :graphql, source)
          super
        end

        def end_dataloader_source(source)
          Transaction.current&.finish_segment(source, prune_below: RubyAPM.config.graphql_field_trace_threshold)
          super
        end

        def dataloader_fiber_yield(source)
          Transaction.current&.suspend_fiber
          super
        end

        def dataloader_fiber_resume(source)
          super
          Transaction.current&.resume_fiber
        end

        private

        def name_transaction(txn, queries)
          return unless @nf_set_name

          txn.name = GraphQL.transaction_name(queries)
          query = queries.first
          txn.attributes["graphql.operation_type"] = GraphQL.operation_type(query)
          op_name = GraphQL.operation_name(query)
          txn.attributes["graphql.operation_name"] = op_name if op_name
          txn.attributes["graphql.queries"] = queries.size if queries.size > 1
        rescue StandardError => e
          Subscribers.warn(e)
        end

        def traced_field_name(field)
          cached = @nf_field_names[field]
          return cached unless cached.nil?

          traced = if field.trace.nil?
                     @nf_trace_scalars || !leaf?(field)
                   else
                     field.trace
                   end
          @nf_field_names[field] = traced ? "GraphQL/field/#{field.owner.graphql_name}.#{field.graphql_name}" : false
        end

        def leaf?(field)
          field.type.unwrap.kind.leaf?
        rescue StandardError
          false
        end
      end

      module_function

      def segment(name, prune: false)
        txn = Transaction.current
        return yield unless txn

        segment = txn.start_segment(name, :graphql)
        begin
          yield
        ensure
          txn.finish_segment(segment, prune_below: prune ? RubyAPM.config.graphql_field_trace_threshold : nil)
        end
      end

      def operation_type(query)
        query&.selected_operation&.operation_type || "query"
      rescue StandardError
        "query"
      end

      VALID_NAME = /\A[_A-Za-z][_0-9A-Za-z]{0,99}\z/

      # Clients choose operation names; anything that isn't a plain GraphQL
      # name (or is absurdly long) is not trusted as a transaction name.
      def operation_name(query)
        name = (query&.selected_operation_name rescue nil)
        return nil if name.nil?
        name.to_s.match?(VALID_NAME) ? name.to_s : "<invalid>"
      end

      # GraphQL/query/ProductList, GraphQL/mutation/CreateOrder, or
      # GraphQL/query/<anonymous> for unnamed operations.
      def transaction_name(queries)
        names = queries.map do |q|
          op = operation_type(q)
          "#{op}/#{operation_name(q) || '<anonymous>'}"
        end.uniq
        names.size == 1 ? "GraphQL/#{names.first}" : "GraphQL/multiplex/#{names.first(5).join('+')}"
      end

      def install!
        return if @installed
        return unless defined?(::GraphQL::Schema)

        # Schemas already loaded, plus any defined later (autoloaded in development).
        install_into_schemas
        ::GraphQL::Schema.singleton_class.prepend(SchemaHook)
        @installed = true
      end

      module SchemaHook
        def inherited(child)
          super
          GraphQL.install_into(child)
        end
      end

      def install_into(schema)
        return if schema.trace_modules_for(:default).include?(Trace)
        schema.trace_with(Trace)
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def install_into_schemas
        ObjectSpace.each_object(Class).select { |k| k < ::GraphQL::Schema }.each { |schema| install_into(schema) }
      rescue StandardError => e
        Subscribers.warn(e)
      end
    end
  end
end
