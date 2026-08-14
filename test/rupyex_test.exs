defmodule RupyexTest do
  use ExUnit.Case, async: true

  alias Rupyex.{Bytes, Error, Object, Result, Set}

  setup do
    session = Rupyex.open!()
    on_exit(fn -> Rupyex.close(session) end)
    %{session: session}
  end

  describe "eval/3" do
    test "evaluates an expression", %{session: s} do
      assert {:ok, 3} = Rupyex.eval(s, "1 + 2")
    end

    test "returns the value of the last statement", %{session: s} do
      assert {:ok, 10} = Rupyex.eval(s, "x = 5\nx * 2")
    end

    test "returns a trailing literal", %{session: s} do
      assert {:ok, 1} = Rupyex.eval(s, "1")
      assert {:ok, "done"} = Rupyex.eval(s, "y = 1\n'done'")
    end

    test "returns nil when the last statement is not an expression", %{session: s} do
      assert {:ok, nil} = Rupyex.eval(s, "def f():\n    return 1")
    end

    test "keeps state between calls", %{session: s} do
      assert {:ok, nil} = Rupyex.eval(s, "counter = 0")
      assert {:ok, 1} = Rupyex.eval(s, "counter += 1\ncounter")
      assert {:ok, 2} = Rupyex.eval(s, "counter += 1\ncounter")
    end

    test "binds values before running", %{session: s} do
      assert {:ok, 5} = Rupyex.eval(s, "a + b", bind: [a: 2, b: 3])
      assert {:ok, 6} = Rupyex.eval(s, "sum(xs)", bind: %{"xs" => [1, 2, 3]})
    end

    test "honours an explicit mode", %{session: s} do
      assert {:ok, nil} = Rupyex.eval(s, "1 + 1", mode: :exec)
      assert {:ok, 2} = Rupyex.eval(s, "1 + 1", mode: :eval)
      assert {:error, %Error{kind: :syntax}} = Rupyex.eval(s, "x = 1", mode: :eval)
    end

    test "eval!/3 raises on failure", %{session: s} do
      assert 3 == Rupyex.eval!(s, "1 + 2")
      assert_raise Error, fn -> Rupyex.eval!(s, "1 / 0") end
    end
  end

  describe "errors" do
    test "python exceptions carry class, message and traceback", %{session: s} do
      assert {:error, error} = Rupyex.eval(s, "1 / 0")
      assert %Error{kind: :python, class: "ZeroDivisionError"} = error
      assert error.message =~ "division by zero"
      assert error.traceback =~ "ZeroDivisionError"
    end

    test "syntax errors are reported as such", %{session: s} do
      assert {:error, %Error{kind: :syntax, class: "SyntaxError"}} = Rupyex.eval(s, "def f(:")
    end

    test "tracebacks point at the right line of a multi-statement source", %{session: s} do
      assert {:error, %Error{traceback: traceback}} = Rupyex.eval(s, "a = 1\nb = 2\nc = 1 / 0\nc")
      assert traceback =~ "line 3"
    end

    test "a raised exception keeps the session usable", %{session: s} do
      assert {:error, %Error{class: "ValueError"}} = Rupyex.eval(s, "raise ValueError('nope')")
      assert {:ok, 1} = Rupyex.eval(s, "1")
    end

    test "reading an unknown name fails with NameError", %{session: s} do
      assert {:error, %Error{class: "NameError"}} = Rupyex.get(s, "nope")
    end
  end

  describe "value conversion" do
    test "python to elixir", %{session: s} do
      assert {:ok, nil} = Rupyex.eval(s, "None")
      assert {:ok, true} = Rupyex.eval(s, "True")
      assert {:ok, false} = Rupyex.eval(s, "False")
      assert {:ok, 7} = Rupyex.eval(s, "7")
      assert {:ok, 1.5} = Rupyex.eval(s, "1.5")
      assert {:ok, "héllo"} = Rupyex.eval(s, "'héllo'")
      assert {:ok, [1, 2]} = Rupyex.eval(s, "[1, 2]")
      assert {:ok, {1, 2}} = Rupyex.eval(s, "(1, 2)")
      assert {:ok, %{"a" => 1}} = Rupyex.eval(s, "{'a': 1}")
      assert {:ok, %Bytes{data: "hi"}} = Rupyex.eval(s, "b'hi'")
      assert {:ok, %Bytes{data: "hi"}} = Rupyex.eval(s, "bytearray(b'hi')")
      assert {:ok, %Set{items: items}} = Rupyex.eval(s, "{1, 2}")
      assert Enum.sort(items) == [1, 2]
    end

    test "integers of any size", %{session: s} do
      assert {:ok, big} = Rupyex.eval(s, "2 ** 200")

      assert big ==
               1_606_938_044_258_990_275_541_962_092_341_162_602_522_202_993_782_792_835_301_376

      assert {:ok, ^big} = Rupyex.eval(s, "n", bind: %{"n" => big})
    end

    test "elixir to python", %{session: s} do
      assert {:ok, "<class 'NoneType'>"} = type_of(s, nil)
      assert {:ok, "<class 'bool'>"} = type_of(s, true)
      assert {:ok, "<class 'int'>"} = type_of(s, 42)
      assert {:ok, "<class 'float'>"} = type_of(s, 4.2)
      assert {:ok, "<class 'str'>"} = type_of(s, "text")
      assert {:ok, "<class 'str'>"} = type_of(s, :an_atom)
      assert {:ok, "<class 'bytes'>"} = type_of(s, Bytes.new(<<0, 255>>))
      assert {:ok, "<class 'list'>"} = type_of(s, [1, 2])
      assert {:ok, "<class 'tuple'>"} = type_of(s, {1, 2})
      assert {:ok, "<class 'dict'>"} = type_of(s, %{"a" => 1})
      assert {:ok, "<class 'set'>"} = type_of(s, Set.new([1, 2]))
    end

    test "binaries that are not utf-8 become bytes", %{session: s} do
      assert {:ok, "<class 'bytes'>"} = type_of(s, <<0xFF, 0xFE>>)
    end

    test "round trips", %{session: s} do
      for value <- [nil, true, 1, 1.5, "text", [1, [2, [3]]], {1, {2}}, %{"a" => %{"b" => 1}}] do
        assert {:ok, ^value} = Rupyex.eval(s, "v", bind: %{"v" => value})
      end

      assert {:ok, %Bytes{data: <<1, 2>>}} =
               Rupyex.eval(s, "v", bind: %{"v" => Bytes.new(<<1, 2>>)})
    end

    test "objects with no elixir counterpart", %{session: s} do
      assert {:ok, %Object{class: "function"}} = Rupyex.eval(s, "def f(): pass\nf")
      assert {:ok, %Object{class: "module"}} = Rupyex.eval(s, "import math\nmath")
    end

    test "objects cannot be passed back in", %{session: s} do
      {:ok, object} = Rupyex.eval(s, "def f(): pass\nf")
      assert {:error, %Error{class: "TypeError"}} = Rupyex.eval(s, "v", bind: %{"v" => object})
    end

    test "a recursive container is refused rather than looping forever", %{session: s} do
      assert {:error, %Error{kind: :conversion}} = Rupyex.eval(s, "a = []\na.append(a)\na")
      assert {:ok, 1} = Rupyex.eval(s, "1")
    end

    test "dict keys keep their type", %{session: s} do
      assert {:ok, %{1 => "int", "1" => "str"}} = Rupyex.eval(s, "{1: 'int', '1': 'str'}")
    end

    test "non-finite floats cross as atoms", %{session: s} do
      assert {:ok, :nan} = Rupyex.eval(s, "float('nan')")
      assert {:ok, {:infinity, :neg_infinity}} = Rupyex.eval(s, "(float('inf'), float('-inf'))")

      assert {:ok, ["nan", "inf", "-inf"]} =
               Rupyex.eval(s, "[str(a), str(b), str(c)]",
                 bind: %{"a" => :nan, "b" => :infinity, "c" => :neg_infinity}
               )
    end

    test "atom keys and structs", %{session: s} do
      assert {:ok, "{'a': 1}"} = Rupyex.eval(s, "repr(v)", bind: %{"v" => %{a: 1}})
      assert {:ok, "[('a', 1)]"} = Rupyex.eval(s, "repr(v)", bind: %{"v" => [a: 1]})

      assert {:ok, %{"__struct__" => "Elixir.Date", "year" => 2026}} =
               Rupyex.eval(s, "v", bind: %{"v" => ~D[2026-08-15]})
    end

    test "a term with no Python counterpart is refused", %{session: s} do
      assert {:error, %Error{kind: :conversion}} = Rupyex.eval(s, "v", bind: %{"v" => self()})
      assert {:ok, 1} = Rupyex.eval(s, "1")
    end

    test "nesting deeper than the limit is refused in both directions", %{session: s} do
      deep = Enum.reduce(1..70, 0, fn _, acc -> [acc] end)
      assert {:error, %Error{kind: :conversion}} = Rupyex.eval(s, "v", bind: %{"v" => deep})

      assert {:error, %Error{kind: :conversion}} =
               Rupyex.eval(s, "x = 0\nfor _ in range(70):\n    x = [x]\nx")

      assert {:ok, 1} = Rupyex.eval(s, "1")
    end
  end

  describe "output" do
    test "run/3 captures stdout and stderr", %{session: s} do
      assert {:ok, %Result{value: 7, stdout: "hi\n"}} = Rupyex.run(s, "print('hi')\n7")

      assert {:ok, %Result{stderr: "oops\n"}} =
               Rupyex.run(s, "import sys\nprint('oops', file=sys.stderr)")
    end

    test "output is per call", %{session: s} do
      assert {:ok, %Result{stdout: "one\n"}} = Rupyex.run(s, "print('one')")
      assert {:ok, %Result{stdout: ""}} = Rupyex.run(s, "1")
    end

    test "an error carries what was printed before it", %{session: s} do
      assert {:error, %Error{stdout: "before\n"}} = Rupyex.eval(s, "print('before')\n1 / 0")
    end
  end

  describe "call/4" do
    test "calls builtins", %{session: s} do
      assert {:ok, 3} = Rupyex.call(s, "len", ["abc"])
      assert {:ok, [1, 2, 3]} = Rupyex.call(s, "sorted", [[3, 1, 2]])
    end

    test "calls functions defined in the session", %{session: s} do
      {:ok, _} = Rupyex.eval(s, "def double(x):\n    return x * 2")
      assert {:ok, 42} = Rupyex.call(s, "double", [21])
    end

    test "walks attributes", %{session: s} do
      {:ok, _} = Rupyex.eval(s, "import json")
      assert {:ok, "[1, 2]"} = Rupyex.call(s, "json.dumps", [[1, 2]])
    end

    test "passes keyword arguments", %{session: s} do
      {:ok, _} = Rupyex.eval(s, "import json")
      assert {:ok, ~s({\n  "a": 1\n})} = Rupyex.call(s, "json.dumps", [%{"a" => 1}], indent: 2)
    end

    test "reports an unknown name", %{session: s} do
      assert {:error, %Error{class: "NameError"}} = Rupyex.call(s, "nope", [])
    end

    test "reports an exception raised inside the callable", %{session: s} do
      assert {:error, %Error{class: "TypeError"}} = Rupyex.call(s, "len", [1])
    end

    test "call!/4 raises", %{session: s} do
      assert 3 == Rupyex.call!(s, "len", ["abc"])
      assert_raise Error, fn -> Rupyex.call!(s, "len", [1]) end
    end
  end

  describe "namespace" do
    test "put/get/delete", %{session: s} do
      assert :ok = Rupyex.put(s, "x", %{"a" => [1, 2]})
      assert {:ok, %{"a" => [1, 2]}} = Rupyex.get(s, "x")
      assert {:ok, 2} = Rupyex.eval(s, "len(x['a'])")
      assert :ok = Rupyex.delete(s, "x")
      assert {:error, %Error{class: "NameError"}} = Rupyex.get(s, "x")
    end

    test "vars/2 lists bound names", %{session: s} do
      {:ok, _} = Rupyex.eval(s, "alpha = 1\nbeta = 2")
      assert {:ok, names} = Rupyex.vars(s)
      assert "alpha" in names
      assert "beta" in names
      refute Enum.any?(names, &String.starts_with?(&1, "__"))
    end

    test "reset/2 clears the namespace", %{session: s} do
      {:ok, _} = Rupyex.eval(s, "gamma = 1")
      assert :ok = Rupyex.reset(s)
      assert {:ok, []} = Rupyex.vars(s)
      assert {:error, %Error{class: "NameError"}} = Rupyex.eval(s, "gamma")
      assert {:ok, 1} = Rupyex.eval(s, "1")
    end
  end

  describe "timeouts and interrupts" do
    test "a runaway loop is interrupted", %{session: s} do
      assert {:error, %Error{kind: :timeout}} =
               Rupyex.eval(s, "while True:\n    pass", timeout: 300)

      assert {:ok, 1} = Rupyex.eval(s, "1")
    end

    test "the session default timeout applies" do
      session = Rupyex.open!(timeout: 200)
      on_exit(fn -> Rupyex.close(session) end)
      assert {:error, %Error{kind: :timeout}} = Rupyex.eval(session, "while True:\n    pass")
    end

    test "interrupt/1 aborts a call made by another process", %{session: s} do
      parent = self()

      task =
        Task.async(fn ->
          send(parent, :started)
          Rupyex.eval(s, "while True:\n    pass", timeout: 10_000)
        end)

      assert_receive :started
      # Give the job time to actually start running before interrupting it.
      Process.sleep(200)
      :ok = Rupyex.interrupt(s)

      assert {:error, %Error{kind: :interrupted, class: "KeyboardInterrupt"}} =
               Task.await(task, 10_000)
    end
  end

  describe "sessions" do
    test "each session has its own namespace" do
      a = Rupyex.open!()
      b = Rupyex.open!()
      on_exit(fn -> Enum.each([a, b], &Rupyex.close/1) end)

      {:ok, _} = Rupyex.eval(a, "shared = 'a'")
      {:ok, _} = Rupyex.eval(b, "shared = 'b'")

      assert {:ok, "a"} = Rupyex.eval(a, "shared")
      assert {:ok, "b"} = Rupyex.eval(b, "shared")
    end

    test "one session serves several processes", %{session: s} do
      results =
        1..8
        |> Task.async_stream(fn i -> Rupyex.eval(s, "n * 2", bind: %{"n" => i}) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "several sessions run at the same time" do
      sessions = for _ <- 1..4, do: Rupyex.open!()
      on_exit(fn -> Enum.each(sessions, &Rupyex.close/1) end)

      results =
        sessions
        |> Task.async_stream(fn s -> Rupyex.eval(s, "sum(range(2000))") end, max_concurrency: 4)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == {:ok, 1_999_000}))
    end

    test "a closed session refuses work" do
      session = Rupyex.open!()
      assert :ok = Rupyex.close(session)
      refute Rupyex.Session.open?(session)
      assert {:error, %Error{kind: :closed}} = Rupyex.eval(session, "1")
      assert :ok = Rupyex.close(session)
    end

    test "init code runs at start-up" do
      session = Rupyex.open!(init: "import math\nPI = math.pi")
      on_exit(fn -> Rupyex.close(session) end)
      assert {:ok, 3.141592653589793} = Rupyex.eval(session, "PI")
    end

    test "a failing init script is reported by open/1" do
      assert {:error, %Error{kind: :init}} = Rupyex.open(init: "1 / 0")
    end

    test "eval_once/2 needs no session" do
      assert {:ok, 4} = Rupyex.eval_once("2 ** 2")
    end

    test "capture_output: false leaves the streams alone" do
      session = Rupyex.open!(capture_output: false)
      on_exit(fn -> Rupyex.close(session) end)
      assert {:ok, %Result{value: 1, stdout: ""}} = Rupyex.run(session, "print('to stdout')\n1")
    end
  end

  describe "standard library" do
    @describetag :stdlib

    test "is embedded", do: assert(Rupyex.stdlib_available?())

    test "json", %{session: s} do
      assert {:ok, %{"a" => 1}} = Rupyex.eval(s, "import json\njson.loads('{\"a\": 1}')")
    end

    test "re", %{session: s} do
      assert {:ok, "2026"} = Rupyex.eval(s, "import re\nre.search(r'\\d+', 'year 2026').group()")
    end

    test "datetime", %{session: s} do
      assert {:ok, "2026-08-14"} =
               Rupyex.eval(s, "import datetime\nstr(datetime.date(2026, 8, 14))")
    end

    test "collections and itertools", %{session: s} do
      assert {:ok, [{"a", 2}]} =
               Rupyex.eval(s, "from collections import Counter\nCounter('aa').most_common()")

      assert {:ok, [{1, "x"}, {1, "y"}]} =
               Rupyex.eval(s, "import itertools\nlist(itertools.product([1], 'xy'))")
    end
  end

  defp type_of(session, value) do
    Rupyex.eval(session, "str(type(v))", bind: %{"v" => value})
  end
end
