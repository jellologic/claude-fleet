#!/usr/bin/env python3
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
"""The DEFAULT conformance checker for a Python frozen port (#57).

    spec-conform.py <port.pyi> <impl path|glob> [more paths…]

A frozen port that nothing checks the implementation against is DECORATIVE. `fleet spec` shows the
port to the worker, makes it read-only, and generates a stub — but until something compares the
CODE to the CONTRACT, a unit can `provides: ["port:Store"]`, never touch `ports/store.pyi` (so the
read-only rule is satisfied), and implement a completely different interface. That is exactly what
the #50 experiment produced, and exactly what its gate (py_compile + an integration test, no
type-checker) failed to notice: the port declared put/get/all, the implementation shipped
add/get/complete/list, and everything was green.

This is the checker of last resort, not the best one. If your repo has mypy/pyright, POINT
`fleet_spec_conform` AT MYPY — it is strictly stronger (it checks types, not just shapes). fleet's
own stack is shell + python3, and on a PEP 668 system `pip install mypy` frequently is not an
option, so fleet ships something that works with nothing but the standard library:

  1. parse the .pyi with `ast`  — the CONTRACT: classes, their methods, module-level functions,
     and the PARAMETER LIST of each;
  2. load the implementation    — by import (so `inspect` sees decorators, inheritance, and
     dynamically-defined methods), falling back to `ast` if the module cannot be imported
     (missing third-party deps, side effects at import time);
  3. compare SHAPES            — every class/function the port declares must EXIST, and every
     method it declares must exist ON THAT CLASS with the SAME PARAMETER LIST.

Exit 0 = conforms. Exit 1 = DRIFT (each drift is named: what the port declares, what the code has).
Exit 2 = usage/parse error.

WHAT THIS CANNOT DO — and you must not let it pretend otherwise. It compares SHAPES: names and
parameter lists. It does not check types, and it cannot check BEHAVIOUR. Measured ceiling for
contract checks in general (STVR 2025, doi:10.1002/stvr.70003): 41/53 seeded integration defects
caught (77%), and 11 of the 12 misses were VALUE-RANGE changes. "They could not replace the service
black-box tests but only complement them." So: PRE-GATE, never the oracle. The TEST SUITE decides.
"""
import ast
import glob as globmod
import importlib.util
import inspect
import os
import sys

SELF = "spec-conform"


def die(msg, code=2):
    print(f"{SELF}: {msg}", file=sys.stderr)
    sys.exit(code)


# ── the CONTRACT: parse the .pyi with ast ────────────────────────────────────────────────
def params_of(fn):
    """Positional + keyword-only parameter NAMES of an ast function def, minus self/cls."""
    a = fn.args
    names = [p.arg for p in (list(getattr(a, "posonlyargs", [])) + list(a.args))]
    if names and names[0] in ("self", "cls"):
        names = names[1:]
    if a.vararg:
        names.append("*" + a.vararg.arg)
    names += [p.arg for p in a.kwonlyargs]
    if a.kwarg:
        names.append("**" + a.kwarg.arg)
    return names


def parse_pyi(path):
    """-> ({class: {method: [params]}}, {function: [params]})"""
    try:
        with open(path) as fh:
            tree = ast.parse(fh.read(), filename=path)
    except OSError as e:
        die(f"cannot read the frozen port {path}: {e}")
    except SyntaxError as e:
        die(f"the frozen port {path} is not parseable Python: {e}")
    classes, funcs = {}, {}
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            if is_type_only(node):
                # A TypedDict / Protocol / NamedTuple / Enum / bare-annotation class in a .pyi is a
                # TYPE the port uses in its signatures — NOT an obligation the implementation must
                # re-declare. Demanding `class Task(TypedDict)` be redefined in store.py made every
                # realistic port permanently non-conformant. (#68)
                continue
            meth = {}
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    meth[sub.name] = params_of(sub)
            classes[node.name] = meth
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs[node.name] = params_of(node)
    return classes, funcs


# Bases that mark a class as a TYPE DECLARATION rather than an interface to implement.
_TYPE_BASES = {"TypedDict", "Protocol", "NamedTuple", "Enum", "IntEnum", "StrEnum"}


def is_type_only(node):
    """True if this ClassDef is a type declaration, not an interface to implement (#68)."""
    for b in node.bases:
        nm = b.attr if isinstance(b, ast.Attribute) else getattr(b, "id", None)
        if nm in _TYPE_BASES:
            return True
    # No methods at all — just annotated fields (`id: str`). That is a data shape, not an interface.
    has_method = any(isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef)) for s in node.body)
    has_ann = any(isinstance(s, (ast.AnnAssign, ast.Assign)) for s in node.body)
    return has_ann and not has_method


# ── the IMPLEMENTATION: import it (inspect), or fall back to ast ─────────────────────────
def sig_params(obj):
    """Parameter names of a live callable, minus self/cls."""
    try:
        sig = inspect.signature(obj)
    except (TypeError, ValueError):
        return None
    names = []
    for p in sig.parameters.values():
        if p.kind is inspect.Parameter.VAR_POSITIONAL:
            names.append("*" + p.name)
        elif p.kind is inspect.Parameter.VAR_KEYWORD:
            names.append("**" + p.name)
        else:
            names.append(p.name)
    if names and names[0] in ("self", "cls"):
        names = names[1:]
    return names


def load_by_import(path):
    """-> ({class: {method: [params]}}, {func: [params]}) or None if it will not import."""
    name = "_fleet_conform_" + os.path.basename(path)[:-3].replace(".", "_")
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        # The implementation usually imports its siblings; make its own directory importable.
        d = os.path.dirname(os.path.abspath(path))
        if d not in sys.path:
            sys.path.insert(0, d)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    except BaseException:
        # A module with import-time side effects, missing deps, or a hard error. NOT fatal: fall
        # back to the static reading. Refusing to check at all here would be the decorative failure
        # this whole file exists to end.
        return None
    classes, funcs = {}, {}
    for nm, obj in vars(mod).items():
        if nm.startswith("_"):
            continue
        if inspect.isclass(obj) and obj.__module__ == name:
            meth = {}
            for mn, mo in inspect.getmembers(obj, callable):
                # Skip inherited object.* noise, but NEVER skip a dunder the class actually defines
                # — `__init__` is the single most commonly declared method in a port, and dropping
                # it made every such port report `__init__` MISSING even when it was right there.
                # (#68 — this bug made the whole conformance check unusable.)
                if mn.startswith("__") and mn not in vars(obj):
                    continue
                p = sig_params(mo)
                if p is not None:
                    meth[mn] = p
            classes[nm] = meth
        elif inspect.isfunction(obj) and obj.__module__ == name:
            p = sig_params(obj)
            if p is not None:
                funcs[nm] = p
    return classes, funcs


def load_by_ast(path):
    try:
        with open(path) as fh:
            tree = ast.parse(fh.read(), filename=path)
    except (OSError, SyntaxError):
        return {}, {}
    classes, funcs = {}, {}
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            classes[node.name] = {
                s.name: params_of(s) for s in node.body
                if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef))
            }
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs[node.name] = params_of(node)
    return classes, funcs


def expand(paths):
    """`owns` paths are globs (src/store/**). Expand to the .py files they cover."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            p = os.path.join(p, "**")
        if any(ch in p for ch in "*?["):
            for f in globmod.glob(p, recursive=True):
                if f.endswith(".py") and os.path.isfile(f):
                    out.append(f)
        elif p.endswith(".py") and os.path.isfile(p):
            out.append(p)
    return sorted(set(out))


def load_impl(files):
    classes, funcs, how = {}, {}, {}
    for f in files:
        got = load_by_import(f)
        mode = "import"
        if got is None:
            got = load_by_ast(f)
            mode = "ast (module would not import)"
        how[f] = mode
        c, fn = got
        for k, v in c.items():
            classes.setdefault(k, {}).update(v)
        funcs.update(fn)
    return classes, funcs, how


# ── the COMPARISON ───────────────────────────────────────────────────────────────────────
def main(argv):
    if len(argv) < 2:
        die("usage: spec-conform.py <port.pyi> <impl path|glob> [more…]")
    port, owns = argv[0], argv[1:]
    # `fleet_spec_conform` passes the unit's owns paths as ONE space-separated argument.
    flat = []
    for o in owns:
        flat += o.split()
    files = expand(flat)
    p_classes, p_funcs = parse_pyi(port)

    if not p_classes and not p_funcs:
        die(f"the frozen port {port} declares NO classes and NO functions — there is nothing to "
            f"conform to. An EMPTY contract passes vacuously, and a contract that passes vacuously "
            f"is decorative. Write the interface, or drop the port.")
    if not files:
        die(f"no Python files found under {' '.join(flat)} — nothing to check against {port}. A "
            f"conformance check with no implementation to check is not a pass.", 1)

    i_classes, i_funcs, how = load_impl(files)
    drift = []

    for cname, meths in sorted(p_classes.items()):
        if cname not in i_classes:
            have = ", ".join(sorted(i_classes)) or "(no classes at all)"
            drift.append(f"MISSING CLASS: the port declares `class {cname}`, the implementation "
                         f"does not define it. It defines: {have}.")
            continue
        impl = i_classes[cname]
        for mname, want in sorted(meths.items()):
            if mname not in impl:
                have = ", ".join(sorted(k for k in impl if not k.startswith("_"))) or "(none)"
                drift.append(f"MISSING METHOD: the port declares `{cname}.{mname}("
                             f"{', '.join(want)})`, the implementation has no such method. "
                             f"`{cname}` defines: {have}.")
                continue
            got = impl[mname]
            if got != want:
                drift.append(f"PARAMETER DRIFT: the port declares `{cname}.{mname}("
                             f"{', '.join(want)})`, the implementation has `{cname}.{mname}("
                             f"{', '.join(got)})`.")
        extra = sorted(k for k in impl if not k.startswith("_") and k not in meths)
        if extra:
            print(f"{SELF}: note: {cname} also defines {', '.join(extra)} — not in the port "
                  f"(allowed: a port is a floor, not a ceiling).")

    for fname, want in sorted(p_funcs.items()):
        if fname not in i_funcs:
            have = ", ".join(sorted(i_funcs)) or "(no module-level functions)"
            drift.append(f"MISSING FUNCTION: the port declares `{fname}({', '.join(want)})`, the "
                         f"implementation does not define it. It defines: {have}.")
            continue
        got = i_funcs[fname]
        if got != want:
            drift.append(f"PARAMETER DRIFT: the port declares `{fname}({', '.join(want)})`, the "
                         f"implementation has `{fname}({', '.join(got)})`.")

    if drift:
        print(f"{SELF}: NON-CONFORMANCE — the implementation does NOT match the frozen port "
              f"{port}:", file=sys.stderr)
        for d in drift:
            print(f"  - {d}", file=sys.stderr)
        print("", file=sys.stderr)
        print(f"  checked: {', '.join(files)}", file=sys.stderr)
        print("  The port is the contract every SIBLING unit is building against right now. An", file=sys.stderr)
        print("  implementation that drifts from it compiles, passes its own tests, and fails at", file=sys.stderr)
        print("  INTEGRATION — the most expensive place for it to fail. Conform to the port. If the", file=sys.stderr)
        print("  PORT is genuinely wrong, that is a manifest bug: stop, say so, and let the", file=sys.stderr)
        print("  orchestrator run `fleet spec amend <port>` on the base branch.", file=sys.stderr)
        return 1

    n = len(p_classes) + len(p_funcs)
    print(f"{SELF}: OK — {len(files)} file(s) conform to {port} "
          f"({n} declared class(es)/function(s)).")
    for f, mode in sorted(how.items()):
        if mode != "import":
            print(f"{SELF}: note: {f} was read statically — {mode}")
    print(f"{SELF}: this is a SHAPE check (names + parameter lists), not a behaviour check. It is a "
          f"PRE-GATE; the TEST SUITE is the oracle.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
