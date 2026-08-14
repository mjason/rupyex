//! One RustPython interpreter per session, living on its own OS thread.
//!
//! Python code must never run on a BEAM scheduler thread: it can block for an
//! unbounded time and RustPython's VM is not `Sync`. Every session therefore
//! owns a thread; NIFs only push a request onto its queue and return
//! immediately, and the answer is delivered to the caller as a message.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use rustler::env::SavedTerm;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, LocalPid, NifTaggedEnum, NifUnitEnum, OwnedEnv};

use rustpython_vm::builtins::{PyBaseExceptionRef, PyCode, PyDictRef, PyStr};
use rustpython_vm::compiler::{ast, parser, Mode};
use rustpython_vm::function::{FuncArgs, KwArgs};
use rustpython_vm::scope::Scope;
use rustpython_vm::signal::{user_signal_channel, UserSignalReceiver, UserSignalSender};
use rustpython_vm::PyRef;
use rustpython_vm::{AsObject, Interpreter, PyObjectRef, PyResult, Settings, VirtualMachine};

use crate::value::{atoms, from_py, Value};

mod reply_atoms {
    rustler::atoms! {
        kind,
        class,
        message,
        traceback,
        stdout,
        stderr,
        python,
        syntax,
        interrupted,
        cancelled,
        conversion,
        init,
        panic,
        pong,
    }
}

/// Python needs a deep native stack; the BEAM's default thread stack is not
/// enough for recursive Python code.
const STACK_SIZE: usize = 32 * 1024 * 1024;

const BOOTSTRAP: &str = r#"
class _RupyexWriter:
    def __init__(self, name):
        self.name = name
        self.encoding = "utf-8"
        self.errors = "strict"
        self._chunks = []

    def write(self, s):
        if not isinstance(s, str):
            s = str(s)
        self._chunks.append(s)
        return len(s)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        pass

    def close(self):
        pass

    def isatty(self):
        return False

    def readable(self):
        return False

    def writable(self):
        return True

    def seekable(self):
        return False

    def fileno(self):
        raise OSError("rupyex output stream has no file descriptor")

    def _rupyex_drain(self):
        out = "".join(self._chunks)
        del self._chunks[:]
        return out

_rupyex_stdout = _RupyexWriter("<stdout>")
_rupyex_stderr = _RupyexWriter("<stderr>")
"#;

#[derive(Debug, NifUnitEnum, Clone, Copy)]
pub enum EvalMode {
    /// Run statements, return the value of the last one (the useful default).
    Block,
    /// A single expression.
    Eval,
    /// Statements only, always returns `nil`.
    Exec,
}

#[derive(Debug, NifTaggedEnum)]
pub enum Request {
    /// Round-trip that also surfaces interpreter start-up failures.
    Ping,
    Eval {
        code: String,
        mode: EvalMode,
        bind: Vec<(String, Value)>,
        file: String,
    },
    /// Call a dotted path resolved against the session globals, then builtins.
    Call {
        target: String,
        args: Vec<Value>,
        kwargs: Vec<(String, Value)>,
    },
    Get {
        name: String,
    },
    Set {
        name: String,
        value: Value,
    },
    Delete {
        name: String,
    },
    /// Names bound in the session globals (dunders excluded).
    Vars,
    /// Throw the globals away and start from a clean namespace.
    Reset,
}

#[derive(Debug, Clone, Copy)]
pub enum ErrorKind {
    Python,
    Syntax,
    Interrupted,
    Cancelled,
    Conversion,
    Init,
    Panic,
}

impl ErrorKind {
    fn encode<'a>(self, env: Env<'a>) -> rustler::Term<'a> {
        match self {
            ErrorKind::Python => reply_atoms::python().encode(env),
            ErrorKind::Syntax => reply_atoms::syntax().encode(env),
            ErrorKind::Interrupted => reply_atoms::interrupted().encode(env),
            ErrorKind::Cancelled => reply_atoms::cancelled().encode(env),
            ErrorKind::Conversion => reply_atoms::conversion().encode(env),
            ErrorKind::Init => reply_atoms::init().encode(env),
            ErrorKind::Panic => reply_atoms::panic().encode(env),
        }
    }
}

#[derive(Debug)]
pub struct ErrorInfo {
    pub kind: ErrorKind,
    pub class: String,
    pub message: String,
    pub traceback: String,
}

impl ErrorInfo {
    fn new(kind: ErrorKind, class: &str, message: impl Into<String>) -> Self {
        Self {
            kind,
            class: class.to_string(),
            message: message.into(),
            traceback: String::new(),
        }
    }
}

#[derive(Debug)]
pub struct Reply {
    pub result: Result<Value, ErrorInfo>,
    pub stdout: String,
    pub stderr: String,
}

impl Reply {
    fn err(info: ErrorInfo) -> Self {
        Self {
            result: Err(info),
            stdout: String::new(),
            stderr: String::new(),
        }
    }
}

impl Encoder for Reply {
    fn encode<'a>(&self, env: Env<'a>) -> rustler::Term<'a> {
        let out = self.stdout.encode(env);
        let err = self.stderr.encode(env);
        match &self.result {
            Ok(value) => {
                let mut io = rustler::Term::map_new(env);
                io = io.map_put(reply_atoms::stdout(), out).unwrap();
                io = io.map_put(reply_atoms::stderr(), err).unwrap();
                make_tuple(env, &[atoms::ok().encode(env), value.encode(env), io])
            }
            Err(info) => {
                let mut map = rustler::Term::map_new(env);
                map = map
                    .map_put(reply_atoms::kind(), info.kind.encode(env))
                    .unwrap();
                map = map
                    .map_put(reply_atoms::class(), info.class.encode(env))
                    .unwrap();
                map = map
                    .map_put(reply_atoms::message(), info.message.encode(env))
                    .unwrap();
                map = map
                    .map_put(reply_atoms::traceback(), info.traceback.encode(env))
                    .unwrap();
                map = map.map_put(reply_atoms::stdout(), out).unwrap();
                map = map.map_put(reply_atoms::stderr(), err).unwrap();
                make_tuple(env, &[atoms::error().encode(env), map])
            }
        }
    }
}

/// Where a job's answer goes: the caller's mailbox, tagged with its ref.
pub struct ReplyTo {
    env: OwnedEnv,
    tag: SavedTerm,
    pid: LocalPid,
}

impl ReplyTo {
    pub fn new(env: Env<'_>, tag: rustler::Term<'_>) -> Self {
        let owned = OwnedEnv::new();
        let saved = owned.save(tag);
        Self {
            env: owned,
            tag: saved,
            pid: env.pid(),
        }
    }

    fn send(self, reply: Reply) {
        let ReplyTo { mut env, tag, pid } = self;
        let _ = env.send_and_clear(&pid, move |env| {
            let tag = tag.load(env);
            make_tuple(env, &[tag, reply.encode(env)])
        });
    }
}

pub struct Job {
    id: u64,
    request: Request,
    reply_to: ReplyTo,
}

#[derive(Debug, Default)]
pub struct Shared {
    /// Id of the job currently executing (0 when idle).
    running: AtomicU64,
    /// Jobs asked to abort before or while they run.
    cancelled: Mutex<HashSet<u64>>,
    closed: AtomicBool,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct SessionOpts {
    /// Make the embedded Python standard library importable.
    pub stdlib: bool,
    /// Redirect `sys.stdout`/`sys.stderr` into the reply instead of the OS ones.
    pub capture_output: bool,
    /// Extra `sys.path` entries for importing real `.py` files.
    pub sys_path: Vec<String>,
    /// `sys.argv`.
    pub argv: Vec<String>,
    /// Python source executed once, right after start-up.
    pub init: Option<String>,
}

pub struct Session {
    tx: Mutex<Option<Sender<Job>>>,
    signal: Mutex<UserSignalSender>,
    shared: Arc<Shared>,
    next_id: AtomicU64,
}

#[rustler::resource_impl]
impl rustler::Resource for Session {}

impl Session {
    pub fn open(opts: SessionOpts) -> std::io::Result<Self> {
        let (tx, rx) = channel::<Job>();
        let (signal_tx, signal_rx) = user_signal_channel();
        let shared = Arc::new(Shared::default());
        let worker_shared = Arc::clone(&shared);

        std::thread::Builder::new()
            .name("rupyex-session".to_string())
            .stack_size(STACK_SIZE)
            .spawn(move || worker(rx, signal_rx, opts, worker_shared))?;

        Ok(Self {
            tx: Mutex::new(Some(tx)),
            signal: Mutex::new(signal_tx),
            shared,
            next_id: AtomicU64::new(1),
        })
    }

    pub fn submit(&self, request: Request, reply_to: ReplyTo) -> Result<u64, &'static str> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let guard = self.tx.lock().unwrap();
        let tx = guard.as_ref().ok_or("session is closed")?;
        tx.send(Job {
            id,
            request,
            reply_to,
        })
        .map_err(|_| "session thread is gone")?;
        Ok(id)
    }

    /// Ask a job to stop. Queued jobs are dropped; a running one gets a
    /// `KeyboardInterrupt` raised inside the VM at its next safe point.
    ///
    /// Job id `0` means "whatever is running right now", which is how another
    /// process can abort a call it did not make itself.
    pub fn interrupt(&self, job_id: u64) {
        if job_id != 0 {
            self.shared.cancelled.lock().unwrap().insert(job_id);
        }
        let shared = Arc::clone(&self.shared);
        let signal = self.signal.lock().unwrap();
        let _ = signal.send(Box::new(move |vm| {
            let running = shared.running.load(Ordering::SeqCst);
            if running != 0 && (job_id == 0 || running == job_id) {
                Err(vm.new_exception_msg(
                    vm.ctx.exceptions.keyboard_interrupt.to_owned(),
                    "execution interrupted".to_string().into(),
                ))
            } else {
                Ok(())
            }
        }));
    }

    pub fn close(&self) {
        self.shared.closed.store(true, Ordering::SeqCst);
        // Dropping the sender ends the worker's receive loop.
        let mut guard = self.tx.lock().unwrap();
        *guard = None;
    }

    pub fn is_open(&self) -> bool {
        !self.shared.closed.load(Ordering::SeqCst) && self.tx.lock().unwrap().is_some()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.close();
    }
}

fn build_settings(opts: &SessionOpts) -> Settings {
    let mut settings = Settings::default();
    // Never touch process-wide signal dispositions: this runs inside the BEAM.
    settings.install_signal_handlers = false;
    settings.isolated = true;
    settings.ignore_environment = true;
    settings.import_site = false;
    settings.user_site_directory = false;
    settings.write_bytecode = false;
    settings.safe_path = true;
    settings.quiet = true;
    settings.argv = opts.argv.clone();
    settings.path_list = opts.sys_path.clone();
    settings
}

fn build_interpreter(opts: &SessionOpts, signal_rx: UserSignalReceiver) -> Interpreter {
    let mut builder = Interpreter::builder(build_settings(opts));

    #[cfg(feature = "stdlib")]
    if opts.stdlib {
        let defs = rustpython_stdlib::stdlib_module_defs(&builder.ctx);
        builder = builder.add_native_modules(&defs);
        builder = builder.add_frozen_modules(rustpython_pylib::FROZEN_STDLIB);
    }

    builder
        .init_hook(move |vm| vm.set_user_signal_channel(signal_rx))
        .build()
}

struct State {
    globals: PyDictRef,
    stdout: Option<PyObjectRef>,
    stderr: Option<PyObjectRef>,
}

impl State {
    fn new(vm: &VirtualMachine, opts: &SessionOpts) -> PyResult<Self> {
        let (stdout, stderr) = if opts.capture_output {
            let scope = vm.new_scope_with_builtins();
            vm.run_string(scope.clone(), BOOTSTRAP, "<rupyex>".to_owned())?;
            let out = scope.globals.get_item("_rupyex_stdout", vm)?;
            let err = scope.globals.get_item("_rupyex_stderr", vm)?;
            let sys = vm.sys_module.as_object();
            sys.set_attr("stdout", out.clone(), vm)?;
            sys.set_attr("stderr", err.clone(), vm)?;
            sys.set_attr("__stdout__", out.clone(), vm)?;
            sys.set_attr("__stderr__", err.clone(), vm)?;
            (Some(out), Some(err))
        } else {
            (None, None)
        };

        let mut state = Self {
            globals: vm.ctx.new_dict(),
            stdout,
            stderr,
        };
        state.init_globals(vm)?;

        if let Some(code) = &opts.init {
            let scope = Scope::with_builtins(None, state.globals.clone(), vm);
            vm.run_string(scope, code, "<rupyex init>".to_owned())?;
        }
        Ok(state)
    }

    fn init_globals(&mut self, vm: &VirtualMachine) -> PyResult<()> {
        self.globals
            .set_item("__name__", vm.ctx.new_str("__main__").into(), vm)?;
        self.globals.set_item("__doc__", vm.ctx.none(), vm)?;
        Ok(())
    }

    fn drain(&self, vm: &VirtualMachine, which: Option<&PyObjectRef>) -> String {
        let Some(obj) = which else {
            return String::new();
        };
        match vm.call_method(obj, "_rupyex_drain", ()) {
            Ok(text) => text
                .downcast_ref::<PyStr>()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default(),
            Err(_) => String::new(),
        }
    }

    fn handle(&mut self, vm: &VirtualMachine, request: Request) -> Result<Value, ErrorInfo> {
        match request {
            Request::Ping => Ok(Value::Str("pong".to_string())),
            Request::Eval {
                code,
                mode,
                bind,
                file,
            } => self.eval(vm, &code, mode, bind, &file),
            Request::Call {
                target,
                args,
                kwargs,
            } => self.call(vm, &target, args, kwargs),
            Request::Get { name } => self.get(vm, &name),
            Request::Set { name, value } => {
                let obj = value.to_py(vm).map_err(|e| exception_info(vm, e))?;
                self.globals
                    .set_item(name.as_str(), obj, vm)
                    .map_err(|e| exception_info(vm, e))?;
                Ok(Value::None)
            }
            Request::Delete { name } => {
                self.globals
                    .del_item(name.as_str(), vm)
                    .map_err(|e| exception_info(vm, e))?;
                Ok(Value::None)
            }
            Request::Vars => {
                let names = self
                    .globals
                    .keys_vec()
                    .into_iter()
                    .filter_map(|key| {
                        key.downcast_ref::<PyStr>()
                            .map(|s| s.to_string_lossy().into_owned())
                    })
                    .filter(|name| !name.starts_with("__"))
                    .map(Value::Str)
                    .collect();
                Ok(Value::List(names))
            }
            Request::Reset => {
                self.globals = vm.ctx.new_dict();
                self.init_globals(vm).map_err(|e| exception_info(vm, e))?;
                Ok(Value::None)
            }
        }
    }

    fn eval(
        &mut self,
        vm: &VirtualMachine,
        code: &str,
        mode: EvalMode,
        bind: Vec<(String, Value)>,
        file: &str,
    ) -> Result<Value, ErrorInfo> {
        for (name, value) in bind {
            let obj = value.to_py(vm).map_err(|e| exception_info(vm, e))?;
            self.globals
                .set_item(name.as_str(), obj, vm)
                .map_err(|e| exception_info(vm, e))?;
        }

        let plan = compile_plan(vm, code, mode, file)?;
        let scope = Scope::with_builtins(None, self.globals.clone(), vm);

        let mut result = vm.ctx.none();
        for code_obj in plan {
            result = vm
                .run_code_obj(code_obj, scope.clone())
                .map_err(|e| exception_info(vm, e))?;
        }
        convert_result(vm, &result)
    }

    fn call(
        &mut self,
        vm: &VirtualMachine,
        target: &str,
        args: Vec<Value>,
        kwargs: Vec<(String, Value)>,
    ) -> Result<Value, ErrorInfo> {
        let callable = self.resolve(vm, target)?;

        let mut py_args = Vec::with_capacity(args.len());
        for arg in args {
            py_args.push(arg.to_py(vm).map_err(|e| exception_info(vm, e))?);
        }
        let mut py_kwargs = Vec::with_capacity(kwargs.len());
        for (name, value) in kwargs {
            py_kwargs.push((name, value.to_py(vm).map_err(|e| exception_info(vm, e))?));
        }

        let func_args = FuncArgs::new(py_args, py_kwargs.into_iter().collect::<KwArgs>());
        let result = callable
            .call(func_args, vm)
            .map_err(|e| exception_info(vm, e))?;
        convert_result(vm, &result)
    }

    fn resolve(&self, vm: &VirtualMachine, target: &str) -> Result<PyObjectRef, ErrorInfo> {
        let mut parts = target.split('.');
        let head = parts.next().unwrap_or("");
        let mut current = match self
            .globals
            .get_item_opt(head, vm)
            .map_err(|e| exception_info(vm, e))?
        {
            Some(obj) => obj,
            None => {
                let attr = vm.ctx.new_str(head);
                vm.builtins.as_object().get_attr(&attr, vm).map_err(|_| {
                    ErrorInfo::new(
                        ErrorKind::Python,
                        "NameError",
                        format!("name '{head}' is not defined"),
                    )
                })?
            }
        };
        for part in parts {
            let attr = vm.ctx.new_str(part);
            current = current
                .get_attr(&attr, vm)
                .map_err(|e| exception_info(vm, e))?;
        }
        Ok(current)
    }

    fn get(&self, vm: &VirtualMachine, name: &str) -> Result<Value, ErrorInfo> {
        match self
            .globals
            .get_item_opt(name, vm)
            .map_err(|e| exception_info(vm, e))?
        {
            Some(obj) => convert_result(vm, &obj),
            None => Err(ErrorInfo::new(
                ErrorKind::Python,
                "NameError",
                format!("name '{name}' is not defined"),
            )),
        }
    }
}

/// Compile source into the code objects to run in order; the value of the last
/// one is the result.
///
/// `Block` mode is assembled here rather than with the VM's `Mode::BlockExpr`,
/// whose codegen mis-handles a trailing literal (it pops an instruction it only
/// assumes is there) and can crash the interpreter. Splitting the source into
/// "statements" and "trailing expression" keeps to the two well-worn paths.
fn compile_plan(
    vm: &VirtualMachine,
    source: &str,
    mode: EvalMode,
    file: &str,
) -> Result<Vec<PyRef<PyCode>>, ErrorInfo> {
    match mode {
        EvalMode::Eval => Ok(vec![compile(vm, source, Mode::Eval, file)?]),
        EvalMode::Exec => Ok(vec![compile(vm, source, Mode::Exec, file)?]),
        EvalMode::Block => {
            // A source that is one whole expression is by far the common case.
            if let Ok(code) = vm.compile(source, Mode::Eval, file.to_owned()) {
                return Ok(vec![code]);
            }

            match split_trailing_expression(source) {
                Some((statements, tail)) => {
                    let mut plan = Vec::with_capacity(2);
                    if !statements.trim().is_empty() {
                        plan.push(compile(vm, statements, Mode::Exec, file)?);
                    }
                    plan.push(compile(vm, &tail, Mode::Eval, file)?);
                    Ok(plan)
                }
                // Either there is no trailing expression, or the source does not
                // parse at all - in which case `Mode::Exec` reports it properly.
                None => Ok(vec![compile(vm, source, Mode::Exec, file)?]),
            }
        }
    }
}

fn compile(
    vm: &VirtualMachine,
    source: &str,
    mode: Mode,
    file: &str,
) -> Result<PyRef<PyCode>, ErrorInfo> {
    vm.compile(source, mode, file.to_owned()).map_err(|err| {
        let exc = vm.new_syntax_error(&err, Some(source));
        let mut info = exception_info(vm, exc);
        info.kind = ErrorKind::Syntax;
        info
    })
}

/// Split module source into everything but its last statement and that
/// statement, when the last one is an expression.
///
/// The tail is padded with newlines so line numbers in tracebacks still line up
/// with the source the caller wrote.
fn split_trailing_expression(source: &str) -> Option<(&str, String)> {
    let parsed = parser::parse_module(source).ok()?;
    let last = parsed.syntax().body.last()?;
    let ast::Stmt::Expr(expr) = last else {
        return None;
    };

    let start = usize::from(expr.range.start());
    if !source.is_char_boundary(start) {
        return None;
    }
    let (statements, tail) = source.split_at(start);
    let padding = "\n".repeat(statements.matches('\n').count());
    Some((statements, padding + tail))
}

fn convert_result(vm: &VirtualMachine, obj: &PyObjectRef) -> Result<Value, ErrorInfo> {
    from_py(obj, vm).map_err(|e| {
        let mut info = exception_info(vm, e);
        info.kind = ErrorKind::Conversion;
        info
    })
}

fn exception_info(vm: &VirtualMachine, exc: PyBaseExceptionRef) -> ErrorInfo {
    let class = exc.class().name().to_string();
    let message = exc
        .as_object()
        .str(vm)
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();

    let mut traceback = String::new();
    if vm.write_exception(&mut traceback, &exc).is_err() {
        let _ = write!(traceback, "{class}: {message}");
    }

    let kind = match class.as_str() {
        "SyntaxError" | "IndentationError" | "TabError" => ErrorKind::Syntax,
        "KeyboardInterrupt" => ErrorKind::Interrupted,
        _ => ErrorKind::Python,
    };

    ErrorInfo {
        kind,
        class,
        message,
        traceback,
    }
}

fn worker(
    rx: Receiver<Job>,
    signal_rx: UserSignalReceiver,
    opts: SessionOpts,
    shared: Arc<Shared>,
) {
    let interpreter = match catch_unwind(AssertUnwindSafe(|| build_interpreter(&opts, signal_rx))) {
        Ok(interpreter) => interpreter,
        Err(_) => return drain_with_error(rx, "interpreter start-up panicked"),
    };

    let state = interpreter.enter(|vm| State::new(vm, &opts));
    let mut state = match state {
        Ok(state) => state,
        Err(exc) => {
            let info = interpreter.enter(|vm| {
                let mut info = exception_info(vm, exc);
                info.kind = ErrorKind::Init;
                info
            });
            return drain_with_info(rx, info);
        }
    };

    while let Ok(job) = rx.recv() {
        let Job {
            id,
            request,
            reply_to,
        } = job;

        if shared.cancelled.lock().unwrap().remove(&id) {
            reply_to.send(Reply::err(ErrorInfo::new(
                ErrorKind::Cancelled,
                "Cancelled",
                "job was cancelled before it started",
            )));
            continue;
        }

        shared.running.store(id, Ordering::SeqCst);
        let reply = interpreter.enter(|vm| {
            let outcome = catch_unwind(AssertUnwindSafe(|| state.handle(vm, request)));
            let stdout = state.drain(vm, state.stdout.as_ref());
            let stderr = state.drain(vm, state.stderr.as_ref());
            let result = match outcome {
                Ok(result) => result,
                Err(payload) => Err(ErrorInfo::new(
                    ErrorKind::Panic,
                    "InterpreterPanic",
                    panic_message(payload),
                )),
            };
            Reply {
                result,
                stdout,
                stderr,
            }
        });
        shared.running.store(0, Ordering::SeqCst);
        // Job ids only grow and are handled in order, so anything up to this
        // one is stale — a cancellation that arrived after its job had already
        // finished. Drop those instead of accumulating them for the life of
        // the session.
        shared.cancelled.lock().unwrap().retain(|&other| other > id);

        reply_to.send(reply);
    }

    interpreter.finalize(None);
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "the interpreter thread panicked".to_string()
    }
}

fn drain_with_error(rx: Receiver<Job>, message: &str) {
    drain_with_info(rx, ErrorInfo::new(ErrorKind::Init, "InitError", message));
}

fn drain_with_info(rx: Receiver<Job>, info: ErrorInfo) {
    while let Ok(job) = rx.recv() {
        job.reply_to.send(Reply::err(ErrorInfo {
            kind: info.kind,
            class: info.class.clone(),
            message: info.message.clone(),
            traceback: info.traceback.clone(),
        }));
    }
}
