//! Rustler NIF exposing an embedded RustPython interpreter to Elixir.
//!
//! The NIFs themselves never run Python code; they hand a request to a session
//! thread and return at once, so a BEAM scheduler is never blocked by a Python
//! program, however long it runs.

mod session;
mod value;

use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};

use session::{ReplyTo, Request, Session, SessionOpts};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        closed,
        conversion,
    }
}

fn raise(message: impl Into<String>) -> rustler::Error {
    rustler::Error::RaiseTerm(Box::new(message.into()))
}

#[rustler::nif]
fn session_open(opts: SessionOpts) -> NifResult<ResourceArc<Session>> {
    Session::open(opts)
        .map(ResourceArc::new)
        .map_err(|err| raise(format!("could not start the session thread: {err}")))
}

/// Queue a request. The answer arrives as `{tag, reply}` in the caller's
/// mailbox; the returned job id can be handed to `session_interrupt/2`.
///
/// Returns `{:ok, job_id}`, or `{:error, kind, message}` when the request holds
/// something that cannot become a Python value, or the session is gone. A
/// caller passing an odd term should get an error, not an exception.
#[rustler::nif]
fn session_submit<'a>(
    env: Env<'a>,
    session: ResourceArc<Session>,
    tag: Term<'a>,
    request: Term<'a>,
) -> Term<'a> {
    let request = match request.decode::<Request>() {
        Ok(request) => request,
        Err(_) => {
            return (
                atoms::error(),
                atoms::conversion(),
                "the request holds a term that cannot be converted to a Python \
                 value (an unsupported type, or nesting deeper than 64 levels)",
            )
                .encode(env)
        }
    };

    let reply_to = ReplyTo::new(env, tag);
    match session.submit(request, reply_to) {
        Ok(job_id) => (atoms::ok(), job_id).encode(env),
        Err(message) => (atoms::error(), atoms::closed(), message).encode(env),
    }
}

#[rustler::nif]
fn session_interrupt(session: ResourceArc<Session>, job_id: u64) -> Atom {
    session.interrupt(job_id);
    atoms::ok()
}

#[rustler::nif]
fn session_close(session: ResourceArc<Session>) -> Atom {
    session.close();
    atoms::ok()
}

#[rustler::nif(name = "session_open?")]
fn session_is_open(session: ResourceArc<Session>) -> bool {
    session.is_open()
}

/// Whether this build embeds the Python standard library.
#[rustler::nif(name = "stdlib_available?")]
fn stdlib_available() -> bool {
    cfg!(feature = "stdlib")
}

rustler::init!("Elixir.Rupyex.Native");
