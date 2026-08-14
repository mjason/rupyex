//! Bridge type between BEAM terms and Python objects.
//!
//! Neither side can be touched from the other's thread: a `Term` is only valid
//! inside its `Env` and a `PyObjectRef` is only valid on the interpreter
//! thread. `Value` is the owned, thread-safe intermediate both sides convert
//! to, which keeps the NIF boundary and the VM boundary independent.

use std::str::FromStr;

use malachite_bigint::BigInt;
use num_traits::ToPrimitive;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Decoder, Encoder, Env, Error as NifError, NifResult, Term, TermType};

use rustpython_vm::builtins::{
    PyByteArray, PyBytes, PyDict, PyFloat, PyFrozenSet, PyInt, PyList, PySet, PyStr, PyTuple,
};
use rustpython_vm::{AsObject, PyObject, PyObjectRef, PyPayload, PyResult, VirtualMachine};

/// Guards against self-referential Python containers and pathological nesting.
pub const MAX_DEPTH: usize = 64;

pub mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        true_ = "true",
        false_ = "false",
        struct_ = "__struct__",
        data,
        items,
        class,
        repr,
        nan,
        infinity,
        neg_infinity,
        bytes_struct = "Elixir.Rupyex.Bytes",
        set_struct = "Elixir.Rupyex.Set",
        object_struct = "Elixir.Rupyex.Object",
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    None,
    Bool(bool),
    Int(i64),
    /// Integers outside the i64 range, kept as a decimal string.
    Big(String),
    Float(f64),
    Str(String),
    Bytes(Vec<u8>),
    List(Vec<Value>),
    Tuple(Vec<Value>),
    Map(Vec<(Value, Value)>),
    Set(Vec<Value>),
    /// Anything with no faithful Elixir counterpart (class instances,
    /// functions, modules, ...). Carries the class name and `repr()`.
    Object {
        class: String,
        repr: String,
    },
    /// An Elixir atom other than `nil`/`true`/`false`; becomes a Python `str`.
    Atom(String),
}

fn binary_term<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut bin = OwnedBinary::new(bytes.len()).expect("failed to allocate binary");
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.release(env).to_term(env)
}

impl Encoder for Value {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Value::None => atoms::nil().encode(env),
            Value::Bool(b) => b.encode(env),
            Value::Int(i) => i.encode(env),
            Value::Big(s) => match rustler::BigInt::parse_bytes(s.as_bytes(), 10) {
                Some(big) => big.encode(env),
                // Unreachable in practice; degrade to the decimal string.
                None => s.encode(env),
            },
            // A BEAM float is always finite: handing enif_make_double a NaN or
            // an infinity yields a non-value that corrupts the term being
            // built, so these three cross as atoms instead.
            Value::Float(f) if f.is_nan() => atoms::nan().encode(env),
            Value::Float(f) if f.is_infinite() && f.is_sign_positive() => {
                atoms::infinity().encode(env)
            }
            Value::Float(f) if f.is_infinite() => atoms::neg_infinity().encode(env),
            Value::Float(f) => f.encode(env),
            Value::Str(s) => s.encode(env),
            Value::Atom(s) => s.encode(env),
            Value::Bytes(b) => struct_term(
                env,
                atoms::bytes_struct().encode(env),
                &[(atoms::data().encode(env), binary_term(env, b))],
            ),
            Value::List(items) => {
                let terms: Vec<Term<'a>> = items.iter().map(|v| v.encode(env)).collect();
                terms.encode(env)
            }
            Value::Tuple(items) => {
                let terms: Vec<Term<'a>> = items.iter().map(|v| v.encode(env)).collect();
                rustler::types::tuple::make_tuple(env, &terms)
            }
            Value::Map(pairs) => {
                let mut map = Term::map_new(env);
                for (k, v) in pairs {
                    map = map
                        .map_put(k.encode(env), v.encode(env))
                        .expect("map_put on a map");
                }
                map
            }
            Value::Set(items) => {
                let terms: Vec<Term<'a>> = items.iter().map(|v| v.encode(env)).collect();
                struct_term(
                    env,
                    atoms::set_struct().encode(env),
                    &[(atoms::items().encode(env), terms.encode(env))],
                )
            }
            Value::Object { class, repr } => struct_term(
                env,
                atoms::object_struct().encode(env),
                &[
                    (atoms::class().encode(env), class.encode(env)),
                    (atoms::repr().encode(env), repr.encode(env)),
                ],
            ),
        }
    }
}

fn struct_term<'a>(env: Env<'a>, name: Term<'a>, fields: &[(Term<'a>, Term<'a>)]) -> Term<'a> {
    let mut map = Term::map_new(env);
    map = map
        .map_put(atoms::struct_().encode(env), name)
        .expect("map_put on a map");
    for (k, v) in fields {
        map = map.map_put(*k, *v).expect("map_put on a map");
    }
    map
}

impl<'a> Decoder<'a> for Value {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        decode_value(term, 0)
    }
}

fn decode_value(term: Term<'_>, depth: usize) -> NifResult<Value> {
    if depth > MAX_DEPTH {
        return Err(NifError::RaiseTerm(Box::new(
            "term nesting too deep for Python conversion".to_string(),
        )));
    }
    match term.get_type() {
        TermType::Atom => {
            let name = term.atom_to_string()?;
            Ok(match name.as_str() {
                "nil" => Value::None,
                "true" => Value::Bool(true),
                "false" => Value::Bool(false),
                // The counterparts of the float encoding above.
                "nan" => Value::Float(f64::NAN),
                "infinity" => Value::Float(f64::INFINITY),
                "neg_infinity" => Value::Float(f64::NEG_INFINITY),
                _ => Value::Atom(name),
            })
        }
        TermType::Binary => {
            let bin: Binary = term.decode()?;
            match std::str::from_utf8(bin.as_slice()) {
                Ok(s) => Ok(Value::Str(s.to_string())),
                Err(_) => Ok(Value::Bytes(bin.as_slice().to_vec())),
            }
        }
        TermType::Integer => match term.decode::<i64>() {
            Ok(i) => Ok(Value::Int(i)),
            Err(_) => {
                let big: rustler::BigInt = term.decode()?;
                Ok(Value::Big(big.to_string()))
            }
        },
        TermType::Float => Ok(Value::Float(term.decode()?)),
        TermType::List => {
            let mut items = Vec::new();
            for item in term.into_list_iterator()? {
                items.push(decode_value(item, depth + 1)?);
            }
            Ok(Value::List(items))
        }
        TermType::Tuple => {
            let elems = rustler::types::tuple::get_tuple(term)?;
            let mut items = Vec::with_capacity(elems.len());
            for item in elems {
                items.push(decode_value(item, depth + 1)?);
            }
            Ok(Value::Tuple(items))
        }
        TermType::Map => decode_map(term, depth),
        _ => Err(NifError::RaiseTerm(Box::new(format!(
            "cannot convert {:?} to a Python value",
            term.get_type()
        )))),
    }
}

fn decode_map(term: Term<'_>, depth: usize) -> NifResult<Value> {
    let env = term.get_env();
    if let Ok(name) = term.map_get(atoms::struct_().encode(env)) {
        if name == atoms::bytes_struct().encode(env) {
            let bin: Binary = term.map_get(atoms::data().encode(env))?.decode()?;
            return Ok(Value::Bytes(bin.as_slice().to_vec()));
        }
        if name == atoms::object_struct().encode(env) {
            // Round-tripping an opaque object is meaningless: nothing crossed
            // the boundary but its name and repr. Rebuild the Value so the VM
            // side can explain that rather than silently passing a dict.
            let class = term
                .map_get(atoms::class().encode(env))
                .and_then(|t| t.decode::<String>())
                .unwrap_or_default();
            let repr = term
                .map_get(atoms::repr().encode(env))
                .and_then(|t| t.decode::<String>())
                .unwrap_or_default();
            return Ok(Value::Object { class, repr });
        }
        if name == atoms::set_struct().encode(env) {
            let items_term = term.map_get(atoms::items().encode(env))?;
            let mut items = Vec::new();
            for item in items_term.into_list_iterator()? {
                items.push(decode_value(item, depth + 1)?);
            }
            return Ok(Value::Set(items));
        }
    }

    let iter = term
        .decode::<rustler::MapIterator>()
        .map_err(|_| NifError::BadArg)?;
    let mut pairs = Vec::new();
    for (k, v) in iter {
        pairs.push((decode_value(k, depth + 1)?, decode_value(v, depth + 1)?));
    }
    Ok(Value::Map(pairs))
}

impl Value {
    /// Build the Python object this value describes.
    pub fn to_py(&self, vm: &VirtualMachine) -> PyResult<PyObjectRef> {
        self.to_py_inner(vm, 0)
    }

    fn to_py_inner(&self, vm: &VirtualMachine, depth: usize) -> PyResult<PyObjectRef> {
        if depth > MAX_DEPTH {
            return Err(vm.new_value_error("term nesting too deep for Python conversion"));
        }
        let obj = match self {
            Value::None => vm.ctx.none(),
            Value::Bool(b) => vm.ctx.new_bool(*b).into(),
            Value::Int(i) => vm.ctx.new_int(*i).into(),
            Value::Big(s) => {
                let big = BigInt::from_str(s)
                    .map_err(|_| vm.new_value_error("invalid integer literal"))?;
                vm.ctx.new_int(big).into()
            }
            Value::Float(f) => vm.ctx.new_float(*f).into(),
            Value::Str(s) => vm.ctx.new_str(s.as_str()).into(),
            Value::Atom(s) => vm.ctx.new_str(s.as_str()).into(),
            Value::Bytes(b) => vm.ctx.new_bytes(b.clone()).into(),
            Value::List(items) => {
                let elems = items
                    .iter()
                    .map(|v| v.to_py_inner(vm, depth + 1))
                    .collect::<PyResult<Vec<_>>>()?;
                vm.ctx.new_list(elems).into()
            }
            Value::Tuple(items) => {
                let elems = items
                    .iter()
                    .map(|v| v.to_py_inner(vm, depth + 1))
                    .collect::<PyResult<Vec<_>>>()?;
                vm.ctx.new_tuple(elems).into()
            }
            Value::Map(pairs) => {
                let dict = vm.ctx.new_dict();
                for (k, v) in pairs {
                    let key = k.to_py_inner(vm, depth + 1)?;
                    let val = v.to_py_inner(vm, depth + 1)?;
                    dict.set_item(&*key, val, vm)?;
                }
                dict.into()
            }
            Value::Set(items) => {
                let set = PySet::default().into_ref(&vm.ctx);
                for item in items {
                    set.add(item.to_py_inner(vm, depth + 1)?, vm)?;
                }
                set.into()
            }
            Value::Object { class, repr } => {
                return Err(vm.new_type_error(format!(
                    "cannot pass an opaque Python object back into Python: {class} {repr}"
                )));
            }
        };
        Ok(obj)
    }
}

/// Convert a Python object into its BEAM-side representation.
pub fn from_py(obj: &PyObject, vm: &VirtualMachine) -> PyResult<Value> {
    from_py_inner(obj, vm, 0)
}

fn from_py_inner(obj: &PyObject, vm: &VirtualMachine, depth: usize) -> PyResult<Value> {
    if depth > MAX_DEPTH {
        return Err(vm.new_value_error(
            "value nesting too deep to convert to an Elixir term (recursive container?)",
        ));
    }

    if vm.is_none(obj) {
        return Ok(Value::None);
    }
    if obj.class().is(vm.ctx.types.bool_type) {
        return Ok(Value::Bool(obj.is(vm.ctx.true_value.as_object())));
    }
    if let Some(int) = obj.downcast_ref::<PyInt>() {
        return Ok(match int.as_bigint().to_i64() {
            Some(i) => Value::Int(i),
            None => Value::Big(int.to_str_radix_10()),
        });
    }
    if let Some(float) = obj.downcast_ref::<PyFloat>() {
        return Ok(Value::Float(float.to_f64()));
    }
    if let Some(s) = obj.downcast_ref::<PyStr>() {
        return Ok(Value::Str(s.to_string_lossy().into_owned()));
    }
    if let Some(b) = obj.downcast_ref::<PyBytes>() {
        return Ok(Value::Bytes(b.as_bytes().to_vec()));
    }
    if let Some(b) = obj.downcast_ref::<PyByteArray>() {
        return Ok(Value::Bytes(b.borrow_buf().to_vec()));
    }
    if let Some(list) = obj.downcast_ref::<PyList>() {
        let elems: Vec<PyObjectRef> = list.borrow_vec().to_vec();
        return Ok(Value::List(convert_all(&elems, vm, depth)?));
    }
    if let Some(tuple) = obj.downcast_ref::<PyTuple>() {
        return Ok(Value::Tuple(convert_all(tuple.as_slice(), vm, depth)?));
    }
    if let Some(dict) = obj.downcast_ref::<PyDict>() {
        let mut pairs = Vec::new();
        for (key, value) in dict {
            pairs.push((
                from_py_inner(&key, vm, depth + 1)?,
                from_py_inner(&value, vm, depth + 1)?,
            ));
        }
        return Ok(Value::Map(pairs));
    }
    if let Some(set) = obj.downcast_ref::<PySet>() {
        return Ok(Value::Set(convert_all(&set.elements(), vm, depth)?));
    }
    if let Some(set) = obj.downcast_ref::<PyFrozenSet>() {
        return Ok(Value::Set(convert_all(&set.elements(), vm, depth)?));
    }

    let class = obj.class().name().to_string();
    let repr = obj
        .repr(vm)
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|_| format!("<{class} object>"));
    Ok(Value::Object { class, repr })
}

fn convert_all(items: &[PyObjectRef], vm: &VirtualMachine, depth: usize) -> PyResult<Vec<Value>> {
    items
        .iter()
        .map(|item| from_py_inner(item, vm, depth + 1))
        .collect()
}
