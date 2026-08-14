defmodule Rupyex.Native do
  @moduledoc """
  Raw NIF bindings for the RustPython interpreter.

  Nothing here blocks a scheduler: `session_submit/3` only queues a request on
  the session's own OS thread and returns a job id, and the answer is delivered
  to the calling process as `{tag, reply}`.

  Use `Rupyex` instead of calling these directly.

  ## Precompiled

  The NIF ships precompiled for the platforms below, so installing Rupyex needs
  no Rust toolchain. To build from source instead — for an unlisted platform, or
  to work on the crate — set `RUPYEX_BUILD=1`, or:

      config :rustler_precompiled, :force_build, rupyex: true

  Building needs Rust 1.93+ and takes a few minutes the first time. A debug
  build of RustPython is slow enough to be misleading, so the crate is always
  built in release mode.
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :rupyex,
    crate: "rupyex_nif",
    base_url: "https://github.com/mjason/rupyex/releases/download/v#{version}",
    version: version,
    force_build:
      System.get_env("RUPYEX_BUILD") in ["1", "true"] or
        Application.compile_env(:rustler_precompiled, [:force_build, :rupyex], false),
    mode: :release,
    nif_versions: ["2.15"],
    targets: [
      "aarch64-apple-darwin",
      "x86_64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-gnu",
      "x86_64-pc-windows-msvc"
    ]

  @typedoc "Opaque handle to a session thread."
  @type session :: reference()

  @doc "Start an interpreter thread. Returns the session resource."
  @spec session_open(map()) :: session()
  def session_open(_opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queue `request`; the reply is sent to the calling process as `{tag, reply}`.

  Returns `{:ok, job_id}` — the id `session_interrupt/2` can abort — or
  `{:error, :conversion | :closed, message}`.
  """
  @spec session_submit(session(), reference(), tuple() | atom()) ::
          {:ok, non_neg_integer()} | {:error, atom(), String.t()}
  def session_submit(_session, _tag, _request), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Abort a queued or running job."
  @spec session_interrupt(session(), non_neg_integer()) :: :ok
  def session_interrupt(_session, _job_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop the interpreter thread and release its memory."
  @spec session_close(session()) :: :ok
  def session_close(_session), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Whether the session still accepts requests."
  @spec session_open?(session()) :: boolean()
  def session_open?(_session), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Whether this build embeds the Python standard library."
  @spec stdlib_available?() :: boolean()
  def stdlib_available?, do: :erlang.nif_error(:nif_not_loaded)
end
