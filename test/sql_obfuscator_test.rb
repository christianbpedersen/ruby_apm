require "test_helper"

class SqlObfuscatorTest < Minitest::Test
  def obf(sql) = RubyAPM::SqlObfuscator.build(sql)

  def test_strips_literals_and_groups_in_lists
    s = obf(%(SELECT "users".* FROM "users" WHERE "users"."email" = 'bob@x.com' AND id IN (1, 2, 3) LIMIT 10))
    assert_equal %(SELECT "users".* FROM "users" WHERE "users"."email" = ? AND id IN (...) LIMIT ?), s.sql
    assert_equal "SELECT", s.operation
    assert_equal "users", s.table
  end

  def test_same_shape_same_key
    assert_equal obf("SELECT * FROM a WHERE id = 1").key, obf("select * from a  where id = 99").key.then { obf("SELECT * FROM a WHERE id = 99").key }
  end

  def test_keeps_bind_placeholders_and_identifiers
    s = obf(%(SELECT "t1"."col2" FROM "t1" WHERE "t1"."id" = $1 /* app:shop */))
    assert_equal %(SELECT "t1"."col2" FROM "t1" WHERE "t1"."id" = $1), s.sql
  end

  def test_insert_and_multi_values
    s = obf(%(INSERT INTO "orders" ("a","b") VALUES ('x', 1), ('y', 2), ('z', 3) RETURNING "id"))
    assert_equal %(INSERT INTO "orders" ("a","b") VALUES (?, ?), ... RETURNING "id"), s.sql
    assert_equal "orders", s.table
  end

  def test_update_and_transaction
    assert_equal "products", obf(%(UPDATE "products" SET "stock" = 4 WHERE "id" = 3)).table
    assert_equal "BEGIN", obf("BEGIN").operation
  end
end

class SqlObfuscatorLeakTest < Minitest::Test
  def obf(sql) = RubyAPM::SqlObfuscator.build(sql).sql

  def test_comment_markers_inside_strings_do_not_leak
    assert_equal "SELECT * FROM u WHERE pw = ? AND id = ?", obf("SELECT * FROM u WHERE pw = 'hunter2 -- secret' AND id = 5")
    assert_equal "SELECT * FROM u WHERE a = ?", obf("SELECT * FROM u WHERE a = 'x /* y'")
  end

  def test_quotes_inside_comments_and_escapes
    assert_equal "SELECT ? FROM t", obf("SELECT 'a' /* it's */ FROM t")
    # Ambiguous between dialects: redacted rather than risk a leak.
    assert_equal RubyAPM::SqlObfuscator::REDACTED, obf("SELECT * FROM t WHERE n = 'O\\'Brien secret'")
    assert_equal "SELECT * FROM t WHERE n = ?", obf("SELECT * FROM t WHERE n = 'O''Brien'")
  end

  def test_unterminated_and_dollar_quoted
    assert_equal "SELECT * FROM t WHERE n = ?", obf("SELECT * FROM t WHERE n = 'oops never closed")
    assert_equal "DO ?", obf("DO $body$ BEGIN RAISE 'x'; END $body$")
  end

  def test_postgres_hash_operators_are_not_comments
    assert_equal "SELECT data #> ? FROM t WHERE id = ?", obf("SELECT data #> '{a,b}' FROM t WHERE id = 3")
  end

  def test_large_statements_are_not_cached
    big = "INSERT INTO t (a) VALUES ('#{'x' * 10_000}')"
    a = RubyAPM::SqlObfuscator.call(big)
    refute RubyAPM::SqlObfuscator.instance_variable_get(:@cache).key?(big)
    assert_equal "INSERT INTO t (a) VALUES (?)", a.sql
  end

  # Leaks found in the November 2026 security review.
  def test_backslash_at_end_of_a_standard_string_does_not_leak_the_next_literal
    out = obf(%q{SELECT * FROM users WHERE path = 'C:\' AND api_token = 'sk_live_SECRET'})
    refute_includes out, "sk_live_SECRET"
    out = obf(%q{UPDATE users SET bio = 'ends\', pw = '$2a$12$HASH', email = 'alice@example.com'})
    refute_match(/HASH|alice/, out)
  end

  def test_numbers_hex_exponent_and_nested_comments
    assert_equal "SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ?", obf("SELECT * FROM t WHERE a = 0xDEADBEEF AND b = 1e10 AND c = 12E-3 AND d = .75")
    refute_includes obf("SELECT 1 /* outer /* inner */ ssn=123-45-6789 secret */ FROM t"), "secret"
    assert_equal "SELECT * FROM t WHERE x = ? AND y = ?", obf("SELECT * FROM t WHERE x = $$a$$ AND y = 5")
  end

  def test_identifiers_with_quotes_fail_closed
    refute_includes obf(%q{SELECT "o'brien" FROM t WHERE name = 'secretname'}), "secretname"
  end

  def test_mysql_dialect
    RubyAPM::SqlObfuscator.mysql = true
    assert_equal "SELECT * FROM t WHERE email = ? AND n = ?", obf(%q{SELECT * FROM t WHERE email = "alice@example.com" AND n = 'O\'Brien'})
    refute_includes obf("SELECT * FROM t # password=hunter2\nWHERE a = 1"), "hunter2"
  ensure
    RubyAPM::SqlObfuscator.mysql = false
  end

  def test_scrub_free_text
    assert_equal "no such column: x: SELECT * FROM users WHERE email = ? AND id = ?",
                 RubyAPM::SqlObfuscator.scrub("no such column: x: SELECT * FROM users WHERE email = 'bob@example.com' AND id = 42")
  end
end
