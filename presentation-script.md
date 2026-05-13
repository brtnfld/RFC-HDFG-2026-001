# Presentation Script: RFC-HDFG-2026-001
# String-Based Filter Configuration API for HDF5
#
# Format: walk-through narration as you scroll the document.
# [Section: ...] marks where you are in the RFC.
# Aim for ~20 minutes total.

---

## Opening

Before we get into the document, let me frame what we're here to discuss.

This RFC is about making HDF5 filter configuration easier to use —
for end users typing command-line options, for developers writing
Python or Fortran code, and for anyone trying to read a file and
understand what compression was applied.

The core proposal is simple: let users configure filters with
human-readable strings like `"level=6"` or `"mode=rate, rate=3.5"`,
instead of arrays of opaque unsigned integers. Everything existing
keeps working. Nothing breaks.

Let's walk through it.

---

## [Section: Abstract]

The abstract summarizes the whole design, so let me unpack the key
sentences.

"The current `H5Pset_filter` interface requires users to construct raw
`cd_values` arrays of unsigned int." — That's the root of all three
problems we're solving, and we'll see concrete examples of why that's
painful in the motivation section.

"The proposed design introduces `H5Pappend_filter`." — This is the
new API function. It accepts either the existing raw array or a
key=value string through a tagged union. If you pass a string, the
library asks the filter plugin to translate it into `cd_values`
before storing it.

"Filters opt into string configuration via a new `H5Z_class3_t`
plugin class." — Version 3 of the plugin class struct. It adds two
optional callbacks and a human-readable title field. Existing plugins
don't have to change anything.

"Existing call sites compile and function without modification." —
This is the compatibility guarantee. We'll come back to the one
caveat around older libraries and extra `cd_values` slots.

---

## [Section: Introduction — Purpose and Scope]

The scope section is worth pausing on briefly, both for what's included
and what's explicitly out.

In scope: the new C API functions, the new plugin class, CLI tool
updates, and the Fortran and Java bindings that ship with HDF5.

Out of scope: the filter execution pipeline itself doesn't change at
all. We're only touching configuration. h5py and other external
bindings don't have to change — though we show how they could adopt
the new API if they wanted to.

Also out of scope: there's no `H5Pmodify_filter2`. If you need to
update parameters on an existing filter entry in a copied DCPL, you
still do it the old way — read the `cd_values` out and call
`H5Pmodify_filter` directly. We considered this and decided it was
out of scope for this RFC.

---

## [Section: Motivation — Problem Statement]

This section is where I'd spend a bit of time, because the three
problems motivate every design decision that follows.

**Type punning.** Look at the code example for ZFP in rate mode. To
pass a `double` rate value, you `memcpy` it into two unsigned int
slots. This is endian-sensitive, easy to get wrong, and essentially
impossible to express naturally from Python or Java. Every high-level
binding that supports ZFP has its own hand-rolled translation layer
for this.

**CLI usability.** The h5repack example speaks for itself:
`-f UD=32013,0,4,1,0,0,1074921472`. That number sequence is "ZFP,
rate mode, rate=3.5". External scripts exist specifically to generate
these sequences. Nobody should have to do this.

**Opaque introspection.** When you open a file and see `cd_values`,
you have no idea what they mean without looking up the filter's
documentation and decoding manually. There's no label, no context,
nothing human-readable in the file.

---

## [Section: Motivation — Goals]

Five goals. The most important ones for this discussion are probably
1, 2, and 3.

Goal 1 — string-based configuration — is the headline feature.

Goal 2 — persistent human-readable labels — is the subtler one. The
`filter_title` field gets packed into `cd_values` so it's stored in
the file. That means `h5dump` can show you "ZFP Compression" even
when the plugin isn't installed on the machine doing the inspection.

Goal 3 — full backward compatibility — is the hard constraint. We
don't get to break anything.

---

## [Section: Parameter String Format]

This section defines the syntax for the key=value strings.

The format is comma-separated `key=value` pairs. Keys are
case-insensitive. Leading and trailing whitespace is stripped. Quoted
values handle the edge case of commas inside a value — if your path
contains a comma, wrap it in single quotes.

The examples table is a good quick reference. `"level=6"` for deflate.
`"mode=rate, rate=3.5"` for ZFP. `NULL` for shuffle, which takes no
parameters.

A few specific rules worth noting:

- Bare keys without an `=` sign are valid boolean flags (`"fast_mode"`).
- `"key="` with nothing after the equals sign is rejected — boolean
  flags use bare key syntax, not empty-value syntax.
- Duplicate keys in a single string are rejected.
- The reserved key `filter_title` cannot be used as a parameter name;
  the library injects it.

The format is bounded: 4096 bytes maximum, 64 parameters maximum.
These bounds exist to limit parsing work and to cap exposure if
someone feeds a malformed string.

The formal EBNF grammar at the end of this section is the normative
reference, but you don't need to memorize it — the examples cover
all the common cases.

---

## [Section: Filter Plugin Class Version 3]

This is the plugin author's side of the design.

The version numbering subsection sets some context: there are already
two class struct generations (`H5Z_class1_t` and `H5Z_class2_t`), and
we're adding a third. The version numbering is a bit unintuitive —
`H5Z_class2_t` carries version field value `1`, and `H5Z_class3_t`
carries version field value `2`. That's a pre-existing convention we
can't change. The new constant `H5Z_CLASS_T_VERS_MAX` is set to `2`
and is what the library uses to sanity-check incoming registrations.

The structure definition adds two callbacks and the `filter_title`
field. Both callbacks are optional — a plugin can implement just
`set_config`, just `get_config`, or both.

The `filter_title` field has a 255-byte limit. That's enough for a
meaningful label and ensures the packed title doesn't consume an
unreasonable number of `cd_values` slots.

The legacy plugin hazard in this section is the one real compatibility
risk. If a v3 plugin appends `filter_title` to `cd_values`, a v2
version of the same plugin presented with that file will see a larger
`cd_nelmts` than it expects. Plugins that do an exact equality check
on `cd_nelmts` will fail. The fix is to check `>=` rather than `==`.
This guidance is already in the HDF5 developer documentation; we're
making it explicit here and producing a migration guide alongside
the RFC.

---

## [Section: Public API — H5Pappend_filter]

The `H5Z_params_t` tagged union is the parameter type. Two macros,
`H5Z_PARAMS_STR` and `H5Z_PARAMS_RAW`, cover the common cases. The
usage examples show a full pipeline being built up — shuffle, then
deflate at level 9, then fletcher32 — using a mix of string and raw
forms. Any combination is valid.

The eager plugin loading note is worth calling out explicitly: unlike
`H5Pset_filter`, which stores raw `cd_values` and doesn't touch the
plugin until the dataset is created, `H5Pappend_filter` with a string
loads the plugin at call time. That's intentional — you get a clear
`H5E_NOFILTER` error right at configuration instead of an obscure
failure later during `H5Dcreate`.

The empty-string fast path: if you pass `NULL` or an empty string,
the library treats it as "no parameters" and doesn't try to load the
plugin at all. That makes parameterless filters like shuffle usable
through the string form without forcing them to implement a
`set_config` callback that has nothing to do.

---

## [Section: Public API — Introspection and Developer Helper]

`H5Pget_filter_params_by_idx` is the read-back function. It calls the
filter's `get_config` if available; otherwise it falls back to
formatting the raw `cd_values` as a colon-separated string.

The note on string reconstruction is important for setting user
expectations: the original parameter string is not stored. After
`H5Pappend_filter` converts a string to `cd_values`, only the
`cd_values` are kept. `get_config` reconstructs from those. For most
integer parameters this is lossless. For floating-point parameters it
may not be — if a rate value is quantized when stored as unsigned ints,
the reconstructed string reflects the quantized value, not the original
input. The API documentation says this explicitly, and tests verify
`cd_values` equality, not string equality.

`H5Zconfig_get_param` is the helper that plugin authors use inside
their `set_config` callbacks to look up individual keys. It's in
`H5Zdevelop.h` rather than the public API to keep the public API
surface small. All built-in filter implementations use it.

---

## [Section: Built-in Filter Parameters]

All built-in filters are upgraded to `H5Z_class3_t`. The parameter
tables for each filter are the quick reference you'd share with users.

The key design point here: for SZIP and scale-offset, the `set_config`
callback delegates to the same internal validation code that
`H5Pset_szip` uses. We're not duplicating that logic. This means
the two configuration paths — old and new — stay in sync automatically.

---

## [Section: Thread Safety and Parallel HDF5]

Thread safety: the existing global API lock serializes everything.
No new locking. The one note for future work is that if many threads
encounter an unknown filter simultaneously at startup, they all queue
behind the first one loading the plugin. That's a convoy effect worth
knowing about if you're doing highly concurrent dataset creation.

The parallel HDF5 section has one non-obvious concern: on a
heterogeneous cluster mixing CPU architectures, `strtod` may produce
different bit patterns for the same decimal string on different
platforms. If every rank independently parses `"rate=3.55555555"` and
converts it to a double, you could get slightly different `cd_values`
across ranks, which breaks the collective `H5Dcreate`. The recommended
pattern is to parse on one rank and broadcast the encoded DCPL via
`H5Pencode`/`H5Pdecode`. `H5Pdecode` copies `cd_values` directly
without re-invoking `set_config`, so it's safe across architectures.

---

## [Section: CLI Tool Integration]

The h5repack change is additive. The parser detects whether the values
after the flags field are a key=value string or a raw integer sequence
and dispatches accordingly. The old syntax is unchanged.

For h5dump, the new `PARAMS_STRING` line appears only with `-p`. No
change to default output.

---

## [Section: Language Bindings]

Fortran and Java both have the same underlying problem: neither
language can represent a C union directly. The solutions are idiomatic
for each language.

Fortran uses two thin C shim functions — one for the string form, one
for the raw `cd_values` form — that construct the `H5Z_params_t` and
call `H5Pappend_filter`. The Fortran side exposes a generic interface
that resolves to the right specific procedure based on argument type.
The string handling follows the existing HDF5 Fortran convention for
NUL termination.

Java uses overloaded methods, one taking a `String` and one taking
an `int[]`. The JNI layer constructs the appropriate `H5Z_params_t`
on the native side.

---

## [Section: Compatibility]

This section is worth reading carefully if you maintain a plugin.

The on-disk format is unchanged. Output is byte-identical to
`H5Pset_filter`. No format version bump needed.

`H5Z_class3_t` retains the `name` field from `H5Z_class2_t` in the
same struct slot. It is the canonical, stable identifier for the
filter (e.g., `"zfp"`) and is the designated lookup key for future
name-to-id mapping. In v3, `filter_title` in `cd_values` takes over
the human-readable display role. Plugin authors upgrading to v3
should populate `filter_title` with a short label — the verbose
debug strings some plugins put in the `name` field should be trimmed
down to something like `"ZFP Compression"`.

For v3 plugins with `filter_title = NULL`, `H5Pget_filter2` falls back
to returning the numeric filter ID as a decimal string. That's not
great for user-facing tools, so plugin authors should provide a title.

---

## [Section: Risks]

Four risks are documented. Briefly:

The two-pass callback invariant is the most likely source of bugs in
third-party plugins. The library catches mismatches and returns an
error — it doesn't silently truncate or overflow — but a buggy
callback is still disruptive. The template in the implementation
section shows the right pattern.

The lossy round-trip is a user expectation issue more than a technical
bug. The documentation handles it.

Grammar maintenance: once we ship this format, we support it
indefinitely. The semicolon is reserved for a possible pipeline-string
extension in a future release. Future grammar additions must be
backward-compatible.

Plugin adoption pace is the longest-horizon risk. If third-party
authors are slow to add `set_config`, the string API only benefits
users of built-in filters in the short term. There's no way to force
adoption, but we can lower the barrier with good documentation and
examples.

---

## [Section: Test Plan]

The test plan covers four areas: parser unit tests, callback contract
tests, built-in filter round-trips, and regression tests.

The parser tests are the most mechanical — valid inputs, expected
outputs, and a list of malformed inputs that must each return
`H5E_BADVALUE`. These can all be exercised independently of any
filter registration, which makes them fast and easy to isolate.

The callback contract tests specifically exercise the two-pass
`set_config` invariant and verify that `get_config` output is valid
input to `set_config`.

The regression tests are the ones I'd emphasize most for reviewers:
reg-01 verifies existing v2 plugins are byte-identical, reg-05
verifies h5repack legacy syntax is byte-identical, and reg-06 is the
cross-version read test that validates the `cd_nelmts >= expected`
tolerance in older plugins.

Parallel and thread-safety tests are in separate categories and
require those build configurations.

---

## Closing

That's the full document.

The short summary: we're adding a usability layer on top of the
existing filter machinery. The new API accepts strings; the library
turns them into `cd_values`; everything downstream is unchanged.
Plugins opt in by implementing two optional callbacks. Existing code
needs no changes.

Happy to dig into any section in more detail, or to discuss the open
design decisions around the pipeline-string API and the migration
timeline for built-in filters.
