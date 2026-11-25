module RubyAPM
  # Removes values that tend to be secrets before they leave the process.
  module Redact
    MAX_PATH = 1_000
    # Long segments mixing letters and digits, or with token punctuation:
    # reset/confirmation tokens, signed ids (ActiveStorage), webhook secrets,
    # JWTs. Plain words, slugs and numeric ids are kept.
    TOKEN_SEGMENT = /\A(?=.{16,})(?=[^\/]*\d)(?=[^\/]*[A-Za-z])[A-Za-z0-9_\-.=~%+]+\z|--|\A[A-Za-z0-9_-]{32,}\z/
    DB_ERROR = /\A(?:ActiveRecord::|PG::|Mysql2::|Trilogy::|SQLite3::)/
    DB_DETAIL_LINE = /\A\s*(?:DETAIL|HINT|CONTEXT|LINE \d+|WHERE):/

    module_function

    WORD_SEGMENT = /\A(?:[a-z][a-z_\-.]{0,40}|v\d{1,3})\z/
    ID_SEGMENT = /\A\d+\z/

    # Outbound URLs often carry secrets in the path (Slack/Discord webhooks,
    # Telegram bot tokens, signed URLs). Keep plain lowercase words only.
    def outbound_path(value)
      value.to_s[0, MAX_PATH].split("/", -1).map do |seg|
        if seg.empty? || seg.match?(WORD_SEGMENT) then seg
        elsif seg.match?(ID_SEGMENT) then ":id"
        else ":redacted"
        end
      end.join("/")
    end

    def path(value)
      value.to_s[0, MAX_PATH].split("/", -1).map { |seg| seg.match?(TOKEN_SEGMENT) ? ":redacted" : seg }.join("/")
    end

    # Database errors embed the failing SQL, often with literal values, and
    # PostgreSQL adds DETAIL lines such as "Key (email)=(alice@...)". Those
    # are scrubbed like SQL; config.error_message_filter can redact more.
    def error_message(error, config = RubyAPM.config)
      message = error.respond_to?(:message) ? error.message.to_s : error.to_s
      if error.class.ancestors.any? { |a| a.name.to_s.match?(DB_ERROR) }
        message = message.lines.reject { |l| l.match?(DB_DETAIL_LINE) }.join
        message = SqlObfuscator.scrub(message)
      end
      message = config.error_message_filter.call(message, error).to_s if config.error_message_filter
      message[0, 500]
    rescue StandardError
      error.class.name.to_s
    end
  end
end
