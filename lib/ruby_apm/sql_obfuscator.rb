require "digest/md5"

module RubyAPM
  # Normalizes SQL so that statements differing only in literal values group
  # together, and so no customer data leaves the process.
  module SqlObfuscator
    MAX_LENGTH = 2_000
    CACHE_LIMIT = 2_000
    # Bulk INSERTs can be megabytes each; caching them would hold raw data.
    CACHEABLE_BYTES = 4_096

    # Strings and comments are matched in one left-to-right pass, so a quote
    # inside a comment or "--" inside a string cannot confuse the other.
    # Backslash escapes are honoured (MySQL, E'' strings) and an
    # unterminated literal swallows the rest of the statement rather than
    # leaking it. Dollar-quoted bodies ($$...$$, $tag$...$tag$) count as strings.
    LITERALS = /
      (?<str>[EeNnBbXx]?'(?:[^'\\]|\\.|'')*(?:'|\z))
      | (?<dq>\$(?<tag>[A-Za-z_]\w*)?\$.*?(?:\$\k<tag>\$|\z))
      | (?<comment>\/\*.*?(?:\*\/|\z) | --[^\n]*)
    /mx
    # Kept for the EXPLAIN plan obfuscation.
    STRINGS = /'(?:[^'\\]|\\.|'')*'/
    NUMBERS = /(?<![\w$."])-?\b\d+(?:\.\d+)?\b/
    IN_LISTS = /\bIN\s*\(\s*(?:\?|\$\d+)(?:\s*,\s*(?:\?|\$\d+))*\s*\)/i
    VALUES_LISTS = /\bVALUES\s*(\((?:[^()]|\([^()]*\))*\))(?:\s*,\s*\((?:[^()]|\([^()]*\))*\))+/i
    WHITESPACE = /\s+/
    OPERATION = /\A\s*(?:WITH\b.*?\)\s*)?(SELECT|INSERT|UPDATE|DELETE|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW|CREATE|ALTER|DROP|TRUNCATE|EXPLAIN|LOCK)\b/im
    TABLE_PATTERNS = {
      "SELECT" => /\bFROM\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "DELETE" => /\bFROM\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "INSERT" => /\bINTO\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "UPDATE" => /\bUPDATE\s+"?(?:\w+"?\.)?"?(\w+)"?/i
    }.freeze

    Statement = Struct.new(:sql, :key, :operation, :table, :segment_name)

    @cache = {}
    @mutex = Mutex.new

    module_function

    def call(raw)
      raw = raw.to_s
      cached = @cache[raw]
      return cached if cached

      statement = build(raw)
      return statement if raw.bytesize > CACHEABLE_BYTES

      @mutex.synchronize do
        @cache.clear if @cache.size >= CACHE_LIMIT
        @cache[raw.frozen? ? raw : raw.dup.freeze] = statement
      end
      statement
    end

    def build(raw)
      sql = raw.gsub(LITERALS) { Regexp.last_match(:comment) ? " " : "?" }
      sql = sql.gsub(NUMBERS, "?")
      sql = sql.gsub(IN_LISTS, "IN (...)")
      sql = sql.gsub(VALUES_LISTS) { "VALUES #{Regexp.last_match(1)}, ..." }
      sql = sql.gsub(WHITESPACE, " ").strip
      sql = sql[0, MAX_LENGTH] if sql.length > MAX_LENGTH

      operation = sql[OPERATION, 1]&.upcase || "OTHER"
      table = (pattern = TABLE_PATTERNS[operation]) ? sql[pattern, 1] : nil
      op = operation.downcase
      name = (table ? "Database/#{table}/#{op}" : "Database/#{op}").freeze
      Statement.new(sql.freeze, Digest::MD5.hexdigest(sql), operation, table, name).freeze
    end
  end
end
