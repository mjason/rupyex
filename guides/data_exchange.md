# Data exchange

Values are copied across the boundary, never shared. Elixir terms are converted
to Python objects on the way in and Python objects to Elixir terms on the way
out, always by value. Nothing on either side keeps a reference to the other's
memory, which is what makes it safe for the interpreter to live on its own
thread and to be torn down at any moment.

## The four ways data crosses

```elixir
{:ok, session} = Rupyex.open()

# 1. bind: names set just before the code runs
{:ok, 6} = Rupyex.eval(session, "sum(xs)", bind: %{"xs" => [1, 2, 3]})

# 2. put/get: the session namespace as storage
:ok = Rupyex.put(session, "config", %{"retries" => 3})
{:ok, %{"retries" => 3}} = Rupyex.get(session, "config")

# 3. call: arguments and keyword arguments
{:ok, _} = Rupyex.eval(session, "import json")
{:ok, ~s({"a": 1})} = Rupyex.call(session, "json.dumps", [%{"a" => 1}])

# 4. return values: the value of the last statement comes back
{:ok, %{"total" => 49.8}} = Rupyex.eval(session, "{'total': 49.8}")
```

`bind:` and `Rupyex.put/4` write into the same namespace the code runs in, so a bound
name stays visible to later calls until it is overwritten, deleted with
`Rupyex.delete/3`, or dropped with `Rupyex.reset/2`.

## Python to Elixir

| Python | Elixir |
| --- | --- |
| `None` | `nil` |
| `True` / `False` | `true` / `false` |
| `int` | integer, of any size |
| `float` | float |
| `float('nan')`, `float('inf')`, `float('-inf')` | `:nan`, `:infinity`, `:neg_infinity` |
| `str` | binary |
| `bytes`, `bytearray` | `Rupyex.Bytes` |
| `list` | list |
| `tuple` | tuple |
| `dict` | map |
| `set`, `frozenset` | `Rupyex.Set` |
| everything else | `Rupyex.Object` |

```elixir
{:ok, %{"nested" => %{"deep" => [1, {2, %Rupyex.Set{items: ["x"]}}, %Rupyex.Bytes{data: "z"}]}}} =
  Rupyex.eval(session, "{'nested': {'deep': [1, (2, {'x'}), b'z']}}")
```

Worth knowing:

* **Dict keys keep their type.** `{1: 'int', '1': 'str'}` becomes
  `%{1 => "int", "1" => "str"}`. Tuples and `None` work as keys too, since any
  term can be a map key.
* **`bytes` is not a plain binary.** Both Python `str` and Python `bytes` would
  otherwise arrive as an Elixir binary and become indistinguishable, so `bytes`
  and `bytearray` come back wrapped in `Rupyex.Bytes`. A `bytearray` loses its
  mutability on the way out — it is a copy.
* **Sets are not `MapSet`.** `MapSet`'s internal representation is private, and
  Python sets can hold values (floats, tuples) whose Elixir counterparts compare
  differently. `Rupyex.Set` keeps them in a list; `Rupyex.Set.to_list/1` gets it
  out. The order is Python's, which is arbitrary.
* **Non-finite floats become atoms.** A BEAM float is always finite, so `nan`
  and the infinities cross as `:nan`, `:infinity` and `:neg_infinity` — and are
  converted back to the right float if you send those atoms in.
* **Sharing is not preserved.** One Python object referenced twice arrives as
  two equal Elixir terms: `x = [1]; (x, x)` gives `{[1], [1]}`.

## Elixir to Python

| Elixir | Python |
| --- | --- |
| `nil` | `None` |
| `true` / `false` | `True` / `False` |
| integer, of any size | `int` |
| float | `float` |
| `:nan`, `:infinity`, `:neg_infinity` | `float('nan')`, `float('inf')`, `float('-inf')` |
| any other atom | `str` of its name |
| binary, valid UTF-8 | `str` |
| binary, not valid UTF-8 | `bytes` |
| `Rupyex.Bytes` | `bytes` |
| list | `list` |
| tuple | `tuple` |
| map | `dict` |
| `Rupyex.Set` | `set` |
| any other struct | `dict`, including its `"__struct__"` key |

Worth knowing:

* **Elixir strings are binaries**, so `"text"` becomes a `str`. To send bytes
  that happen to be valid UTF-8, wrap them: `Rupyex.Bytes.new(data)`.
* **Atom map keys become strings.** `%{a: 1}` is `{'a': 1}` in Python — and
  comes back as `%{"a" => 1}`, not `%{a: 1}`. Use string keys for anything that
  makes a round trip.
* **A keyword list is a list of tuples**, because that is what it is:
  `[a: 1, b: 2]` becomes `[('a', 1), ('b', 2)]`, not a dict. Pass a map when you
  want a dict. (The `:bind` option and `call/4`'s keyword arguments are read by
  Rupyex itself, so keyword syntax is fine there.)
* **Charlists are lists of integers**, again because that is what they are:
  `~c"abc"` becomes `[97, 98, 99]`.
* **Structs become plain dicts.** `~D[2026-08-15]` arrives as
  `{'__struct__': 'Elixir.Date', 'year': 2026, 'month': 8, 'day': 15, ...}`.
  There is no `Date`/`DateTime`/`Decimal`/`MapSet` mapping; convert at the edge
  (`Date.to_iso8601/1`, `Decimal.to_string/1`) when Python should see something
  more natural.
* **`Rupyex.Object` cannot go back in.** It is a receipt for an object that
  never left the interpreter, so sending one raises `TypeError`. Keep such
  values in Python and refer to them by name.

## Objects that do not convert

Class instances, functions, modules, generators, `datetime`, `Decimal` and
anything else without an Elixir counterpart come back as a receipt:

```elixir
{:ok, %Rupyex.Object{class: "Decimal", repr: "Decimal('1.5')"}} =
  Rupyex.eval(session, "import decimal\ndecimal.Decimal('1.5')")
```

The object itself stays in the session, where it is still reachable by name, so
the way to work with it is to keep it there and convert only at the end:

```elixir
{:ok, _} = Rupyex.eval(session, "import decimal\nprice = decimal.Decimal('1.5')")

# Not this: the receipt cannot be sent back.
{:ok, "1.5"} = Rupyex.eval(session, "str(price)")
{:ok, 3.0} = Rupyex.eval(session, "float(price * 2)")
```

## When conversion fails

Both directions have limits, and neither crashes the session:

```elixir
# No Python counterpart (a pid, a port, a function).
{:error, %Rupyex.Error{kind: :conversion}} =
  Rupyex.eval(session, "v", bind: %{"v" => self()})

# Nesting deeper than 64 levels, in either direction.
{:error, %Rupyex.Error{kind: :conversion}} =
  Rupyex.eval(session, "x = 0\nfor _ in range(70):\n    x = [x]\nx")

# A container that contains itself: the same depth limit catches it.
{:error, %Rupyex.Error{kind: :conversion}} =
  Rupyex.eval(session, "a = []\na.append(a)\na")

{:ok, 1} = Rupyex.eval(session, "1")
```

`Rupyex.Error` with `kind: :conversion` always means the values could not
cross — the Python code itself may well have run.

## Cost

Conversion happens on the interpreter thread, so it never occupies a scheduler.
It is a copy, and the cost is proportional to the size of the data. Measured on
one machine, for a sense of scale:

| | |
| --- | --- |
| small call round trip (`1 + 1`) | ~50 µs |
| 100k-element list, Elixir to Python | ~6 ms |
| 100k-element list, Python to Elixir | ~13 ms |
| 1 MB binary, either direction | < 1 ms |

Binaries are the cheapest thing to move, integers and floats the next; deep
structures cost the most per byte. If a snippet only needs a slice of a large
structure, it is much cheaper to keep the structure in the session with
`Rupyex.put/4` once and index into it than to bind it on every call.

## What is not there

* **No callbacks.** Python cannot call back into Elixir; all calls start on the
  Elixir side.
* **No object handles.** An opaque object cannot be held from Elixir and used
  later — only named and used from Python.
* **No streaming.** A generator has to be consumed inside Python; results come
  back whole, not in chunks.
