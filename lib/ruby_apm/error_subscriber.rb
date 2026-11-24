module RubyAPM
  # Rails.error subscriber (Rails 7+): remembers what the app reported during
  # a transaction, so a request that rescues an exception and renders a 500
  # still gets the real exception, class and backtrace in its error group.
  class ErrorSubscriber
    def report(error, handled: true, severity: :error, context: {}, source: nil, **)
      return unless error.is_a?(Exception) && severity != :info

      txn = Transaction.current
      txn.reported_error ||= error if txn
    end
  end
end
