defmodule Rupyex.Server do
  @moduledoc """
  A supervised owner for a long-lived session.

  A session lives as long as the struct that refers to it, so something has to
  hold on to it. This server does exactly that and nothing else:

      children = [
        {Rupyex.Server, name: MyApp.Python, init: "import json"}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      {:ok, 3} = Rupyex.Server.eval(MyApp.Python, "1 + 2")

  Python code does **not** run inside this process: `session/1` hands the
  session back and the caller talks to the interpreter thread directly, so one
  slow snippet cannot make the server a bottleneck. When calling in a tight
  loop, fetch the session once and pass it to `Rupyex` yourself.
  """

  use GenServer

  alias Rupyex.Session

  @doc """
  Start a server.

  Takes the options of `Rupyex.Session.open/1`, plus `:name` for the process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The session this server owns."
  @spec session(GenServer.server()) :: Session.t()
  def session(server), do: GenServer.call(server, :session)

  @doc "Run Python source in the server's session. See `Rupyex.eval/3`."
  @spec eval(GenServer.server(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Rupyex.Error.t()}
  def eval(server, code, opts \\ []), do: Rupyex.eval(session(server), code, opts)

  @doc "See `Rupyex.run/3`."
  @spec run(GenServer.server(), String.t(), keyword()) ::
          {:ok, Rupyex.Result.t()} | {:error, Rupyex.Error.t()}
  def run(server, code, opts \\ []), do: Rupyex.run(session(server), code, opts)

  @doc "See `Rupyex.call/4`."
  @spec call(GenServer.server(), String.t(), [term()], keyword() | map()) ::
          {:ok, term()} | {:error, Rupyex.Error.t()}
  def call(server, target, args \\ [], kwargs \\ []),
    do: Rupyex.call(session(server), target, args, kwargs)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Session.open(opts) do
      {:ok, session} -> {:ok, session}
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:session, _from, session), do: {:reply, session, session}

  @impl true
  def terminate(_reason, session), do: Session.close(session)
end
