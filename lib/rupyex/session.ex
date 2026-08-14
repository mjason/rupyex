defmodule Rupyex.Session do
  @moduledoc """
  A live Python interpreter: a namespace plus the thread that runs it.

  A session is a plain struct wrapping a NIF resource, so it can be passed
  between processes and stored in any state. Requests from different processes
  are queued and run one at a time, and each answer goes back to the process
  that asked for it.

  The interpreter thread stops when the session is closed with `close/1` or
  when the struct becomes garbage — hold on to it for as long as you need the
  Python state to survive.

      {:ok, session} = Rupyex.Session.open()
      {:ok, 3} = Rupyex.eval(session, "1 + 2")
      :ok = Rupyex.Session.close(session)
  """

  alias Rupyex.{Error, Native}

  @default_timeout 5_000
  @default_open_timeout 30_000
  # How long to wait for an interrupted job to unwind before giving up on it.
  @interrupt_grace 1_000

  @enforce_keys [:ref]
  defstruct [:ref, timeout: @default_timeout]

  @type t :: %__MODULE__{ref: reference(), timeout: timeout()}

  @typedoc """
  Options for `open/1`:

    * `:stdlib` — make the embedded Python standard library importable
      (default `true`)
    * `:capture_output` — send `sys.stdout`/`sys.stderr` to `Rupyex.Result`
      instead of the OS streams (default `true`); with `false`, Python prints
      land on the BEAM's own stdout
    * `:sys_path` — extra `sys.path` entries, for importing real `.py` files
    * `:argv` — `sys.argv`
    * `:init` — Python source to run once at start-up
    * `:timeout` — default timeout for every call on this session
      (default `#{@default_timeout}` ms)
    * `:open_timeout` — how long to wait for the interpreter to start
      (default `#{@default_open_timeout}` ms)
  """
  @type open_option ::
          {:stdlib, boolean()}
          | {:capture_output, boolean()}
          | {:sys_path, [String.t()]}
          | {:argv, [String.t()]}
          | {:init, String.t() | nil}
          | {:timeout, timeout()}
          | {:open_timeout, timeout()}

  @doc """
  Start an interpreter.

  Blocks until the interpreter is ready, so start-up failures (a broken
  `:init` script, for instance) are reported here rather than on first use.
  """
  @spec open([open_option()]) :: {:ok, t()} | {:error, Error.t()}
  def open(opts \\ []) do
    nif_opts = %{
      stdlib: Keyword.get(opts, :stdlib, true),
      capture_output: Keyword.get(opts, :capture_output, true),
      sys_path: Keyword.get(opts, :sys_path, []),
      argv: Keyword.get(opts, :argv, []),
      init: Keyword.get(opts, :init)
    }

    case start(nif_opts, Keyword.get(opts, :timeout, @default_timeout)) do
      {:ok, session} ->
        # A ping proves the interpreter booted and ran the init code.
        case request(session, :ping,
               timeout: Keyword.get(opts, :open_timeout, @default_open_timeout)
             ) do
          {:ok, _value, _io} ->
            {:ok, session}

          {:error, %Error{} = error} ->
            close(session)
            {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Same as `open/1`, but raises on failure.
  """
  @spec open!([open_option()]) :: t()
  def open!(opts \\ []) do
    case open(opts) do
      {:ok, session} -> session
      {:error, error} -> raise error
    end
  end

  @doc """
  Stop the interpreter and release everything it holds.

  Any queued request fails with a `:closed` error. Closing twice is fine.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}) do
    Native.session_close(ref)
    :ok
  end

  @doc "Whether the session still accepts requests."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{ref: ref}), do: Native.session_open?(ref)

  @doc """
  Abort whatever the session is running right now.

  The running Python code receives a `KeyboardInterrupt` at its next safe
  point, which it may catch. Callers waiting on that job get an
  `:interrupted` error.
  """
  @spec interrupt(t()) :: :ok
  def interrupt(%__MODULE__{ref: ref}) do
    Native.session_interrupt(ref, 0)
    :ok
  end

  @doc false
  @spec request(t(), tuple() | atom(), keyword()) ::
          {:ok, term(), %{stdout: String.t(), stderr: String.t()}} | {:error, Error.t()}
  def request(%__MODULE__{} = session, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, session.timeout)
    tag = make_ref()

    case submit(session, tag, payload) do
      {:ok, job_id} -> await(session, tag, job_id, timeout)
      {:error, _} = error -> error
    end
  end

  defp start(nif_opts, timeout) do
    {:ok, %__MODULE__{ref: Native.session_open(nif_opts), timeout: timeout}}
  rescue
    error ->
      {:error,
       %Error{
         kind: :init,
         class: "SessionError",
         message: "could not start the interpreter: #{Exception.message(error)}"
       }}
  end

  defp submit(%__MODULE__{ref: ref}, tag, payload) do
    case Native.session_submit(ref, tag, payload) do
      {:ok, job_id} ->
        {:ok, job_id}

      {:error, kind, message} ->
        {:error, %Error{kind: kind, class: "SessionError", message: message}}
    end
  rescue
    error ->
      {:error, %Error{kind: :closed, class: "SessionError", message: Exception.message(error)}}
  end

  defp await(session, tag, job_id, timeout) do
    receive do
      {^tag, {:ok, value, io}} -> {:ok, value, io}
      {^tag, {:error, info}} -> {:error, Error.from_map(info)}
    after
      timeout -> abort(session, tag, job_id, timeout)
    end
  end

  defp abort(%__MODULE__{ref: ref}, tag, job_id, timeout) do
    Native.session_interrupt(ref, job_id)

    # Collect whatever the job managed to produce, so a timeout still reports
    # the output and leaves no stale reply in the caller's mailbox.
    {stdout, stderr} =
      receive do
        {^tag, {:ok, _value, io}} -> {io.stdout, io.stderr}
        {^tag, {:error, info}} -> {Map.get(info, :stdout, ""), Map.get(info, :stderr, "")}
      after
        @interrupt_grace -> {"", ""}
      end

    {:error,
     %Error{
       kind: :timeout,
       class: "Timeout",
       message: "Python code did not finish within #{timeout}ms and was interrupted",
       stdout: stdout,
       stderr: stderr
     }}
  end
end
