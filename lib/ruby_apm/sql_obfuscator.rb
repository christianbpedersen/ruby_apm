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
    # inside a comment or "--" inside a string cannot confuse the other. An
    # unterminated literal swallows the rest of the statement rather than
    # leaking it. Backslash escapes only count inside E'' strings: standard
    # SQL (PostgreSQL, SQLite) treats '\' as a plain character, and honouring it
    # there would close the string one quote late and leak the next literal.
    # Comments nest (PostgreSQL). Dollar-quoted bodies count as strings.
    STANDARD = /
      (?<ident>"(?:[^"]|"")*(?:"|\z))
      | (?<str>(?<![\w$])[Ee]'(?:[^'\\]|\\.|'')*(?:'|\z)
             | (?:(?<![\w$])(?:[NnBbXx]|_\w+))?'(?:[^']|'')*(?:'|\z))
      | (?<dq>\$(?<tag>[A-Za-z_]\w*)\$.*?(?:\$\k<tag>\$|\z) | \$\$.*?(?:\$\$|\z))
      | (?<comment>(?<c>\/\*(?:[^*\/]|\*(?!\/)|\/(?!\*)|\g<c>)*(?:\*\/|\z)) | --[^\n]*)
    /mx
    # MySQL: backslash escapes in every string, "..." is a string, # comments.
    MYSQL = /
      (?<ident>`(?:[^`]|``)*(?:`|\z))
      | (?<str>(?:(?<![\w$])(?:[NnBbXx]|_\w+))?'(?:[^'\\]|\\.|'')*(?:'|\z) | "(?:[^"\\]|\\.|"")*(?:"|\z))
      | (?<comment>\/\*.*?(?:\*\/|\z) | (?:--\s|\#)[^\n]*)
    /mx
    # Standard rules, but backslash escapes honoured everywhere: only used to
    # detect statements that read differently under the two conventions.
    BACKSLASH = /
      (?<ident>"(?:[^"]|"")*(?:"|\z))
      | (?<str>(?:(?<![\w$])(?:[EeNnBbXx]|_\w+))?'(?:[^'\\]|\\.|'')*(?:'|\z))
      | (?<dq>\$(?<tag>[A-Za-z_]\w*)\$.*?(?:\$\k<tag>\$|\z) | \$\$.*?(?:\$\$|\z))
      | (?<comment>(?<c>\/\*(?:[^*\/]|\*(?!\/)|\/(?!\*)|\g<c>)*(?:\*\/|\z)) | --[^\n]*)
    /mx
    STRINGS = /'(?:[^']|'')*'/
    IDENT_MARK = "\u0001"
    NUMBERS = /(?<![\w$."])(?:0[xX][0-9A-Fa-f]+|-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)(?![\w.])/
    # Shipped instead of the statement when literals could not be removed with
    # certainty (a quote survived): better an opaque statement than a leak.
    REDACTED = "/* RubyAPM: statement redacted, literals could not be removed safely */"
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
    @mysql = false

    module_function

    # Set from the ActiveRecord adapter at boot (Railtie).
    def mysql=(flag)
      @mutex.synchronize do
        @mysql = flag ? true : false
        @cache.clear
      end
    end

    def mysql? = @mysql

    # Strings and numbers replaced by "?" in free text (exception messages).
    def scrub(text)
      strip_literals(text.to_s, @mysql ? MYSQL : STANDARD)
    end

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

    # A quote outside a quoted identifier means a literal was not consumed.
    def leftover_quote?(sql)
      if @mysql
        sql.gsub(/`(?:[^`]|``)*`/, "").match?(/['"]/)
      else
        sql.gsub(/"(?:[^"]|"")*"/, "").include?("'")
      end
    end

    def strip_literals(raw, pattern)
      # Quoted identifiers stay (they may contain quotes or digits); strings
      # become "?", comments a space, numbers outside identifiers "?".
      kept = []
      out = raw.gsub(pattern) do
        m = Regexp.last_match
        if m[:ident] then kept << m[0]; IDENT_MARK
        elsif m[:comment] then " "
        else "?"
        end
      end
      out.gsub(NUMBERS, "?").gsub(IDENT_MARK) { kept.shift }
    end

    def build(raw)
      sql = strip_literals(raw, @mysql ? MYSQL : STANDARD)
      # A backslash makes quoting dialect-dependent ('C:\' is complete in
      # PostgreSQL, unterminated in MySQL). If the two readings disagree, the
      # statement is ambiguous and could leak under the wrong one: redact it.
      sql = REDACTED if !@mysql && raw.include?("\\") && strip_literals(raw, BACKSLASH) != sql
      sql = REDACTED if leftover_quote?(sql)
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
