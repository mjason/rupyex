# Rupyex

Python as an embedded scripting language for Elixir, built on
[RustPython](https://github.com/RustPython/RustPython) and
[Rustler](https://github.com/rusterlium/rustler).

No Python installation, no ports, no external processes: the interpreter and
the Python standard library are compiled into a NIF and run in your VM.

```elixir
{:ok, session} = Rupyex.open()

{:ok, 3} = Rupyex.eval(session, "1 + 2")
{:ok, nil} = Rupyex.eval(session, "def double(x): return x * 2")
{:ok, 42} = Rupyex.call(session, "double", [21])

{:ok, %{"total" => 6}} =
  Rupyex.eval(session, "{'total': sum(xs)}", bind: %{"xs" => [1, 2, 3]})

:ok = Rupyex.close(session)
```

## Why it is safe to embed

Running a foreign interpreter inside the BEAM is normally a good way to lose a
scheduler. Rupyex avoids that:

* **Python never runs on a scheduler thread.** Each session owns an OS thread.
  A NIF call only queues a request and returns; the answer comes back as a
  message. Nothing blocks, whatever the Python code does.
* **Runaway code is interruptible.** Every call has a timeout (5s by default).
  On expiry the VM is signalled and raises `KeyboardInterrupt` at its next safe
  point, so an infinite loop is stopped rather than leaked.
* **Sessions clean up after themselves.** Close a session explicitly, or let it
  become garbage — the thread stops and the interpreter's memory goes with it.
* **Panics are contained.** A crash inside the interpreter is caught and
  returned as an error instead of taking the node down.

## Installation

```elixir
def deps do
  [{:rupyex, "~> 0.1"}]
end
```

A Rust toolchain is required to build (Rust 1.93+). The first build compiles
RustPython and its standard library, which takes a few minutes; after that it
is cached like any other Rust dependency.

## Usage

### Sessions hold state

A session is a live namespace, like a REPL: names bound by one call are visible
to the next.

```elixir
{:ok, session} = Rupyex.open(init: "import json")

{:ok, _} = Rupyex.eval(session, "config = {'retries': 3}")
{:ok, 3} = Rupyex.eval(session, "config['retries']")
{:ok, ~s({"retries": 3})} = Rupyex.eval(session, "json.dumps(config)")
```

Sessions are cheap (~15 ms to start) but not free, so keep one for as long as
the state matters. For a one-off snippet there is `Rupyex.eval_once/2`.

A session is a plain struct around a NIF resource: pass it between processes
freely. Requests are queued and run one at a time, and each answer goes back to
the process that asked for it. To keep one alive under a supervisor, use
`Rupyex.Server`:

```elixir
children = [{Rupyex.Server, name: MyApp.Python, init: "import json"}]

{:ok, 3} = Rupyex.Server.eval(MyApp.Python, "1 + 2")
```

### Values

| Python | Elixir |
| --- | --- |
| `None` | `nil` |
| `True` / `False` | `true` / `false` |
| `int` | integer (of any size) |
| `float` | float |
| `str` | binary |
| `bytes`, `bytearray` | `Rupyex.Bytes` |
| `list` | list |
| `tuple` | tuple |
| `dict` | map |
| `set`, `frozenset` | `Rupyex.Set` |
| `nan`, `inf`, `-inf` | `:nan`, `:infinity`, `:neg_infinity` |
| anything else | `Rupyex.Object` (class name and `repr`) |

Going the other way, atoms other than `nil`/`true`/`false` become strings, a
binary becomes `str` when it is valid UTF-8 and `bytes` when it is not, and any
other struct becomes a dict — so `%{a: 1}` comes back as `%{"a" => 1}`, and
`[a: 1]` is a list of tuples rather than a dict.

An `Rupyex.Object` is a receipt, not a handle: the object itself never left the
interpreter. Keep working with it by name in Python rather than passing it back.

Values are copied, never shared, and a value that cannot cross (a pid, nesting
deeper than 64 levels, a self-referential container) fails with a
`kind: :conversion` error instead of taking the session down. The
[data exchange guide](guides/data_exchange.md) has the full picture, including
what each direction costs.

### Return values

By default a snippet returns the value of its last statement, so both of these
work:

```elixir
{:ok, 3} = Rupyex.eval(session, "1 + 2")
{:ok, 10} = Rupyex.eval(session, "x = 5\nx * 2")
```

Pass `mode: :eval` to require a single expression, or `mode: :exec` for
statements only (always `nil`).

### Output

`print` output is captured per call. `Rupyex.eval/3` discards it, `Rupyex.run/3`
returns it, and errors carry whatever was printed before they were raised:

```elixir
{:ok, %Rupyex.Result{value: 7, stdout: "hi\n"}} = Rupyex.run(session, "print('hi')\n7")
```

Pass `capture_output: false` to `Rupyex.open/1` to let Python write to the
BEAM's own stdout instead.

### Errors

Failures come back as `{:error, %Rupyex.Error{}}` with the Python class,
message and traceback:

```elixir
{:error, error} = Rupyex.eval(session, "1 / 0")
error.class      #=> "ZeroDivisionError"
error.message    #=> "division by zero"
error.traceback  #=> "Traceback (most recent call last):\n  File \"<rupyex>\", line 1, ..."
```

`error.kind` says where it came from: `:python`, `:syntax`, `:timeout`,
`:interrupted`, `:cancelled`, `:conversion`, `:init`, `:closed` or `:panic`.
The bang variants (`eval!/3`, `call!/4`) raise instead.

### Timeouts and interrupts

```elixir
{:error, %Rupyex.Error{kind: :timeout}} =
  Rupyex.eval(session, "while True:\n    pass", timeout: 500)

{:ok, 1} = Rupyex.eval(session, "1")  # the session is still fine
```

Another process can abort whatever is running with `Rupyex.interrupt/1`.

### Importing real `.py` files

```elixir
{:ok, session} = Rupyex.open(sys_path: ["priv/python"])
{:ok, _} = Rupyex.eval(session, "import my_module")
```

## What you get from Python

RustPython implements Python 3 semantics and ships most of the standard library
(`json`, `re`, `datetime`, `collections`, `itertools`, `math`, `random`,
`hashlib`, `base64`, `threading`, `os`, ...). What it does not have is the C
extension ecosystem — no NumPy, no pandas, nothing that links against CPython's
C API — and it is slower than CPython. It suits embedded scripting: user-defined
rules, formulas, transformations, plugins. It does not suit numeric workloads.

Rupyex is **not a sandbox**. Embedded Python can read and write files and reach
the network, exactly as any Elixir code in your node can. Treat a snippet as
code you run, not as untrusted input.

## Development

```
mix deps.get
mix test
```

The NIF is always built in release mode: a debug build of RustPython is slow
enough to be misleading.

## License

Apache-2.0.
