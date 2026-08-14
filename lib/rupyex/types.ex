defmodule Rupyex.Bytes do
  @moduledoc """
  A Python `bytes` value.

  Elixir strings are binaries, so a plain binary always becomes a Python `str`
  (a binary that is not valid UTF-8 becomes `bytes`). Wrap a binary in this
  struct to force `bytes`:

      Rupyex.eval(session, "len(data)", bind: %{"data" => Rupyex.Bytes.new(<<1, 2, 3>>)})
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary()}

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}
end

defmodule Rupyex.Set do
  @moduledoc """
  A Python `set` or `frozenset`.

  `MapSet` is deliberately not used: its internal representation is private,
  and Python sets can hold values (tuples, floats) whose Elixir counterparts
  compare differently.
  """

  defstruct items: []

  @type t :: %__MODULE__{items: [term()]}

  @spec new(Enumerable.t()) :: t()
  def new(items), do: %__MODULE__{items: Enum.to_list(items)}

  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{items: items}), do: items
end

defmodule Rupyex.Object do
  @moduledoc """
  A Python object with no Elixir counterpart: a class instance, a function, a
  module, a generator...

  Only its class name and `repr()` cross the boundary — the object itself stays
  in the interpreter, where it stays reachable under whatever name it is bound
  to. Work with it by name:

      {:ok, %Rupyex.Object{class: "range_iterator"}} =
        Rupyex.eval(session, "counter = iter(range(3))\ncounter")

      {:ok, 0} = Rupyex.call(session, "next", ["counter"]) # wrong: passes a string
      {:ok, 0} = Rupyex.eval(session, "next(counter)")     # right: name it in Python

  Passing an `Rupyex.Object` back into Python raises a `TypeError`: there is no
  object on the Elixir side to send.
  """

  defstruct [:class, :repr]

  @type t :: %__MODULE__{class: String.t(), repr: String.t()}
end

defmodule Rupyex.Result do
  @moduledoc """
  The value returned by Python code, together with anything it printed.

  Returned by `Rupyex.run/3`. `Rupyex.eval/3` returns the value alone.
  """

  defstruct value: nil, stdout: "", stderr: ""

  @type t :: %__MODULE__{value: term(), stdout: String.t(), stderr: String.t()}
end

defmodule Rupyex.Error do
  @moduledoc """
  A failure raised inside (or around) the interpreter.

  `:kind` says where it came from:

    * `:python` — an exception raised by the Python code
    * `:syntax` — the source did not compile
    * `:timeout` — the call ran past its `:timeout` and was interrupted
    * `:interrupted` — the job was aborted by `Rupyex.interrupt/1`
    * `:cancelled` — the job was aborted before it started running
    * `:conversion` — the value could not be represented as an Elixir term
    * `:init` — the interpreter failed to start
    * `:closed` — the session is no longer running
    * `:panic` — the interpreter thread panicked (a RustPython bug)
  """

  defexception [
    :kind,
    :class,
    :message,
    :traceback,
    stdout: "",
    stderr: ""
  ]

  @type kind ::
          :python
          | :syntax
          | :timeout
          | :interrupted
          | :cancelled
          | :conversion
          | :init
          | :closed
          | :panic

  @type t :: %__MODULE__{
          kind: kind(),
          class: String.t(),
          message: String.t(),
          traceback: String.t() | nil,
          stdout: String.t(),
          stderr: String.t()
        }

  @doc false
  def from_map(%{kind: kind, class: class, message: message} = info) do
    %__MODULE__{
      kind: kind,
      class: class,
      message: message,
      traceback: Map.get(info, :traceback),
      stdout: Map.get(info, :stdout, ""),
      stderr: Map.get(info, :stderr, "")
    }
  end

  @impl true
  def message(%__MODULE__{kind: :python, traceback: traceback}) when is_binary(traceback) do
    String.trim_trailing(traceback)
  end

  def message(%__MODULE__{class: class, message: message}) when is_binary(class) do
    "#{class}: #{message}"
  end

  def message(%__MODULE__{message: message}), do: message
end
