defmodule Rupyex do
  @moduledoc """
  Python as an embedded language for Elixir, powered by
  [RustPython](https://github.com/RustPython/RustPython) through Rustler.

  No Python installation is involved: the interpreter — and, by default, the
  standard library — is compiled into the NIF.

      {:ok, session} = Rupyex.open()

      {:ok, 3} = Rupyex.eval(session, "1 + 2")
      {:ok, nil} = Rupyex.eval(session, "def double(x): return x * 2")
      {:ok, 42} = Rupyex.call(session, "double", [21])

      {:ok, %{"total" => 6}} =
        Rupyex.eval(session, "{'total': sum(xs)}", bind: %{"xs" => [1, 2, 3]})

  ## Sessions hold state

  A session is a live namespace: names bound by one call are visible to the
  next, exactly like a REPL. Sessions are cheap but not free (each owns an OS
  thread), so keep one around for as long as the state matters and close it
  when you are done. For a single throwaway snippet, use `eval_once/2`.

  ## Values

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

  Going the other way, atoms other than `nil`/`true`/`false` become strings,
  and a binary becomes a `str` when it is valid UTF-8 and `bytes` when it is
  not. `Rupyex.Object` values cannot be passed back in — the object never left
  the interpreter, so refer to it by name instead.

  Values are copied rather than shared, and anything that cannot cross fails
  with a `kind: :conversion` error. See the
  [data exchange guide](data_exchange.html) for the whole story.

  ## Timeouts

  Every call takes a `:timeout` (default 5s). Python code that overruns it is
  interrupted with a `KeyboardInterrupt` at its next safe point, so a runaway
  loop cannot pin a scheduler or leak a thread. Python never runs on a BEAM
  scheduler in the first place: each session owns a thread, and calls are
  ordinary message round-trips.

  ## Output

  `print` output is captured per call. `eval/3` discards it; `run/3` returns it
  in a `Rupyex.Result`, and an error carries whatever was printed before it was
  raised. Pass `capture_output: false` to `open/1` to let Python write to the
  BEAM's own stdout instead.
  """

  alias Rupyex.{Error, Native, Result, Session}

  @type session :: Session.t()
  @type value :: term()

  @typedoc """
  Options accepted by `eval/3`, `run/3` and `call/4`:

    * `:timeout` — override the session default for this call
    * `:bind` — names to bind in the session namespace before running the code,
      as a map or keyword list (`eval/3` and `run/3` only)
    * `:mode` — how to compile the source (`eval/3` and `run/3` only):
      * `:block` (default) — run the statements, return the value of the last one
      * `:eval` — a single expression
      * `:exec` — statements only, always returns `nil`
    * `:file` — the file name shown in tracebacks (default `"<rupyex>"`)
  """
  @type option ::
          {:timeout, timeout()}
          | {:bind, map() | keyword()}
          | {:mode, :block | :eval | :exec}
          | {:file, String.t()}

  @doc """
  Start a session. See `Rupyex.Session.open/1` for the options.
  """
  @spec open([Session.open_option()]) :: {:ok, session()} | {:error, Error.t()}
  defdelegate open(opts \\ []), to: Session

  @doc "Start a session, raising on failure."
  @spec open!([Session.open_option()]) :: session()
  defdelegate open!(opts \\ []), to: Session

  @doc "Stop a session."
  @spec close(session()) :: :ok
  defdelegate close(session), to: Session

  @doc "Abort whatever the session is running right now."
  @spec interrupt(session()) :: :ok
  defdelegate interrupt(session), to: Session

  @doc "Whether this build embeds the Python standard library."
  @spec stdlib_available?() :: boolean()
  defdelegate stdlib_available?(), to: Native

  @doc """
  Run Python source and return its value.

      {:ok, 3} = Rupyex.eval(session, "1 + 2")
      {:ok, 6} = Rupyex.eval(session, "x = 1 + 2\\nx * 2")
      {:ok, 5} = Rupyex.eval(session, "a + b", bind: [a: 2, b: 3])

  Anything the code prints is discarded; use `run/3` to keep it.
  """
  @spec eval(session(), String.t(), [option()]) :: {:ok, value()} | {:error, Error.t()}
  def eval(session, code, opts \\ []) do
    with {:ok, %Result{value: value}} <- run(session, code, opts), do: {:ok, value}
  end

  @doc """
  Same as `eval/3`, but returns the value directly and raises `Rupyex.Error`
  on failure.
  """
  @spec eval!(session(), String.t(), [option()]) :: value()
  def eval!(session, code, opts \\ []) do
    unwrap(eval(session, code, opts))
  end

  @doc """
  Run Python source and return its value along with everything it printed.

      {:ok, %Rupyex.Result{value: nil, stdout: "hi\\n"}} =
        Rupyex.run(session, "print('hi')")
  """
  @spec run(session(), String.t(), [option()]) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(session, code, opts \\ []) when is_binary(code) do
    payload =
      {:eval,
       %{
         code: code,
         mode: Keyword.get(opts, :mode, :block),
         bind: bindings(Keyword.get(opts, :bind, [])),
         file: Keyword.get(opts, :file, "<rupyex>")
       }}

    session
    |> Session.request(payload, opts)
    |> to_result()
  end

  @doc """
  Call a Python callable by name and return its value.

  The name is resolved against the session namespace first, then the builtins,
  and may walk attributes:

      {:ok, 3} = Rupyex.call(session, "len", ["abc"])
      {:ok, "[1, 2]"} = Rupyex.call(session, "json.dumps", [[1, 2]])

  Keyword arguments go in a separate list, since Python distinguishes them from
  positional ones:

      {:ok, "{\n  \"a\": 1\n}"} =
        Rupyex.call(session, "json.dumps", [%{"a" => 1}], indent: 2)

  `:timeout` in that list is read as a call option rather than a keyword
  argument; pass a map to send it to Python instead.
  """
  @spec call(session(), String.t(), [value()], keyword() | map()) ::
          {:ok, value()} | {:error, Error.t()}
  def call(session, target, args \\ [], kwargs \\ [])

  def call(session, target, args, kwargs) when is_binary(target) and is_list(args) do
    {kwargs, opts} = split_call_opts(kwargs)

    payload = {:call, %{target: target, args: args, kwargs: bindings(kwargs)}}

    with {:ok, %Result{value: value}} <- to_result(Session.request(session, payload, opts)) do
      {:ok, value}
    end
  end

  @doc "Same as `call/4`, but returns the value directly and raises on failure."
  @spec call!(session(), String.t(), [value()], keyword() | map()) :: value()
  def call!(session, target, args \\ [], kwargs \\ []) do
    unwrap(call(session, target, args, kwargs))
  end

  @doc """
  Read a name from the session namespace.

      :ok = Rupyex.put(session, "x", 1)
      {:ok, 1} = Rupyex.get(session, "x")
  """
  @spec get(session(), String.t(), [option()]) :: {:ok, value()} | {:error, Error.t()}
  def get(session, name, opts \\ []) when is_binary(name) do
    with {:ok, %Result{value: value}} <-
           to_result(Session.request(session, {:get, %{name: name}}, opts)) do
      {:ok, value}
    end
  end

  @doc """
  Bind a name in the session namespace.

      :ok = Rupyex.put(session, "config", %{"retries" => 3})
      {:ok, 3} = Rupyex.eval(session, "config['retries']")
  """
  @spec put(session(), String.t(), value(), [option()]) :: :ok | {:error, Error.t()}
  def put(session, name, value, opts \\ []) when is_binary(name) do
    case to_result(Session.request(session, {:set, %{name: name, value: value}}, opts)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Unbind a name from the session namespace."
  @spec delete(session(), String.t(), [option()]) :: :ok | {:error, Error.t()}
  def delete(session, name, opts \\ []) when is_binary(name) do
    case to_result(Session.request(session, {:delete, %{name: name}}, opts)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The names bound in the session namespace, excluding dunders.
  """
  @spec vars(session(), [option()]) :: {:ok, [String.t()]} | {:error, Error.t()}
  def vars(session, opts \\ []) do
    with {:ok, %Result{value: names}} <- to_result(Session.request(session, :vars, opts)) do
      {:ok, names}
    end
  end

  @doc """
  Throw the namespace away and start from a clean one.

  Imported modules stay loaded in the interpreter; only the names bound in the
  session go.
  """
  @spec reset(session(), [option()]) :: :ok | {:error, Error.t()}
  def reset(session, opts \\ []) do
    case to_result(Session.request(session, :reset, opts)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Run a snippet in a fresh session and throw the session away.

  Convenient for one-off evaluation; if you are going to run more than one
  snippet, `open/1` a session and reuse it — starting an interpreter costs far
  more than a call into one.

      {:ok, 4} = Rupyex.eval_once("2 ** 2")
  """
  @spec eval_once(String.t(), [option() | Session.open_option()]) ::
          {:ok, value()} | {:error, Error.t()}
  def eval_once(code, opts \\ []) when is_binary(code) do
    with {:ok, session} <- open(opts) do
      try do
        eval(session, code, opts)
      after
        close(session)
      end
    end
  end

  defp to_result({:ok, value, io}) do
    {:ok, %Result{value: value, stdout: io.stdout, stderr: io.stderr}}
  end

  defp to_result({:error, _} = error), do: error

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: raise(error)

  # `call/4`'s last argument doubles as kwargs and call options; `:timeout` is
  # the only name Python would otherwise be free to use, so it is claimed here.
  defp split_call_opts(kwargs) when is_map(kwargs), do: {kwargs, []}

  defp split_call_opts(kwargs) when is_list(kwargs) do
    {timeout, kwargs} = Keyword.pop(kwargs, :timeout)
    if timeout, do: {kwargs, [timeout: timeout]}, else: {kwargs, []}
  end

  defp bindings(bind) when is_map(bind), do: Enum.map(bind, &binding_pair/1)
  defp bindings(bind) when is_list(bind), do: Enum.map(bind, &binding_pair/1)

  defp binding_pair({name, value}) when is_binary(name), do: {name, value}
  defp binding_pair({name, value}) when is_atom(name), do: {Atom.to_string(name), value}
end
