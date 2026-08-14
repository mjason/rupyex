defmodule Rupyex.LifecycleTest do
  # Not async: the thread-lifecycle test counts interpreter threads process-wide.
  use ExUnit.Case, async: false

  alias Rupyex.Error

  describe "sys_path" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rupyex_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "greeter.py"), """
      GREETING = "hello"

      def greet(name):
          return f"{GREETING}, {name}"
      """)

      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "imports a real .py file", %{dir: dir} do
      session = Rupyex.open!(sys_path: [dir])
      on_exit(fn -> Rupyex.close(session) end)

      assert {:ok, "hello, world"} =
               Rupyex.eval(session, "import greeter\ngreeter.greet('world')")
    end

    test "a module outside sys.path is not importable" do
      session = Rupyex.open!()
      on_exit(fn -> Rupyex.close(session) end)

      assert {:error, %Error{class: "ModuleNotFoundError"}} =
               Rupyex.eval(session, "import greeter")
    end
  end

  describe "resource lifecycle" do
    test "the interpreter thread goes away when the session becomes garbage" do
      before = python_thread_count()

      task =
        Task.async(fn ->
          session = Rupyex.open!()
          {:ok, 1} = Rupyex.eval(session, "1")
          :ok
        end)

      assert :ok = Task.await(task)

      # The session struct died with the task; the NIF resource is collected and
      # the thread stops. GC is not instantaneous, so give it a moment.
      assert eventually(fn -> python_thread_count() <= before end)
    end
  end

  describe "Rupyex.Server" do
    test "owns a session for as long as it lives" do
      start_supervised!({Rupyex.Server, name: :rupyex_test_server, init: "seed = 41"})

      assert {:ok, 42} = Rupyex.Server.eval(:rupyex_test_server, "seed + 1")
      assert {:ok, 3} = Rupyex.Server.call(:rupyex_test_server, "len", ["abc"])

      assert %Rupyex.Result{stdout: "hi\n"} =
               elem(Rupyex.Server.run(:rupyex_test_server, "print('hi')"), 1)

      session = Rupyex.Server.session(:rupyex_test_server)
      assert Rupyex.Session.open?(session)

      stop_supervised!(Rupyex.Server)
      refute Rupyex.Session.open?(session)
    end

    test "reports a failing init script" do
      Process.flag(:trap_exit, true)
      assert {:error, %Error{kind: :init}} = Rupyex.Server.start_link(init: "1 / 0")
    end
  end

  defp python_thread_count do
    case File.ls("/proc/self/task") do
      {:ok, tasks} ->
        Enum.count(tasks, fn tid ->
          case File.read("/proc/self/task/#{tid}/comm") do
            {:ok, name} -> String.trim(name) == "rupyex-session"
            _ -> false
          end
        end)

      _ ->
        0
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(100)
        {:cont, false}
      end
    end)
  end
end
