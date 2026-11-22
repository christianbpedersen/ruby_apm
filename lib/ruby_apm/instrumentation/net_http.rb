require "net/http"

module RubyAPM
  module Instrumentation
    # Outbound HTTP made with Net::HTTP (and libraries built on it: Faraday's
    # default adapter, HTTParty, ActiveResource, most SDKs).
    module NetHttp
      module Request
        def request(req, body = nil, &block)
          txn = Transaction.current
          # Unstarted connections re-enter #request from inside #start.
          return super unless txn && started?

          segment = txn.start_segment(Subscribers::Names.get("External", address, req.method), :external)
          response = nil
          begin
            response = super
          ensure
            txn.finish_segment(segment)
            if segment.in_tree
              segment.attrs = { "url" => "#{use_ssl? ? 'https' : 'http'}://#{address}:#{port}#{req.path.to_s.split('?').first}",
                                "status" => response&.code }
            end
          end
        end
      end

      module_function

      def install!
        return if @installed
        ::Net::HTTP.prepend(Request)
        @installed = true
      end
    end
  end
end
