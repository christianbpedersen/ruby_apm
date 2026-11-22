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
    assert_equal "SELECT * FROM t WHERE n = ?", obf("SELECT * FROM t WHERE n = 'O\\'Brien secret'")
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
end
