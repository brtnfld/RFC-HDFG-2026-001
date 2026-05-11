# Switching to TOML: Parameter String Format
## RFC-HDFG-2026-001

---

## Why We Had a Custom Parser — and Why We Dropped It

The original design used a hand-written comma-separated `key=value` parser
with RFC 4180-style quoting for values containing commas.

**What it required the library to own:**
- A bespoke grammar (EBNF written and maintained by us)
- A stateful parser (~80 lines of C)
- Quoting semantics decisions (what escapes are valid?)
- All edge cases: bare keys as boolean flags, `key=` rejection, etc.

**The problem:** every design question — *can a key contain a hyphen?
what does `key=` mean? how do you embed a quote?* — had to be answered
from scratch and documented by us, forever.

---

## The Old Design's Specific Gaps

| Problem | Old grammar |
|---------|-------------|
| Typed values | Everything a string; filter had to re-parse `"3.5"` → `double` |
| Booleans | Bare key (`fast_mode`) as implicit true — non-standard, surprising |
| Nested config | Not supported; VOL/VFD parameters had no clean path |
| Specification | Our spec, our burden, our compatibility surface |
| Parser | Vendored nowhere; we wrote and own it |

A single accessor, `H5Zconfig_get_param`, returned a `char *` for
everything. Type dispatch was the filter's problem.

---

## TOML: An Established Inline Table Grammar

TOML v1.0.0 is a stable, widely-used configuration language.
The **inline table** subset — `{key = value, key = value}` — is exactly
the shape we need for filter parameters.

**What we get for free:**
- A published, versioned specification we reference rather than write
- Native typed values: integer, float, boolean, string
- Defined escaping rules (no new decisions)
- Nested tables for VOL/VFD config and wrapping filters (e.g., Blosc sub-compressor)
- An MIT-licensed C17 implementation: **tomlc17**

We vendor a stripped subset of tomlc17 under `src/H5Ztoml.{c,h}`.
The TOML v1.0.0 grammar is stable; no API-breaking changes are expected.

---

## What the Subset Looks Like

Outer braces are **optional**. The library wraps bare strings internally.

```
level = 6                                              # integer
mode = "rate", rate = 3.5                             # string + float
fast_mode = true, level = 6                           # boolean + integer
path = "/data/run_1,v2/dict.bin"                      # comma inside quoted string
pixels_per_block = 16, coding = "nn"                  # SZIP
compressor.name = "zlib", compressor.level = 6, shuffle = 1  # Blosc2 (dotted keys)
compressor = {name = "zlib", level = 6}, shuffle = 1  # Blosc2 (inline table; equivalent)
stripe = {size = 1048576, count = 4}                  # nested table (VOL/VFD)
NULL                                                   # no parameters
```

**HDF5-specific constraints on top of TOML:**
- `filter_title` is a reserved key (injected by the library)
- `inf`, `-inf`, `nan` are valid TOML but rejected by HDF5
- Arrays, datetimes, multi-line strings are not in the supported subset
- Max 4096 bytes, max 64 top-level keys

---

## What Changed for Plugin Authors

**Typed accessors replace the single string accessor:**

| Old | New |
|-----|-----|
| `H5Zconfig_get_param(params, "level", buf, &sz)` → string | `H5Zconfig_get_int(params, "level", &val)` → `int64_t` |
| Manual `strtod("3.5")` in the callback | `H5Zconfig_get_double(params, "rate", &val)` → `double` |
| `H5Zconfig_get_param` → check `buf_size == 0` for bare-key boolean | `H5Zconfig_get_bool(params, "fast_mode", &val)` → `hbool_t` |

**Booleans:** `fast_mode` (bare key, old) → `fast_mode = true` (TOML).
Bare keys without a value are now rejected with `H5E_BADVALUE`.

**Type mismatches are caught at the parser level**, before `set_config`
is invoked. A `rate = "oops"` passed to `H5Zconfig_get_double` returns
`H5E_BADVALUE` immediately.

---

## What Did Not Change

- The `H5Pappend_filter` API signature is unchanged
- `cd_values` storage is unchanged — TOML is an input format only
- `get_config` output format is unchanged (still `key = value` strings)
- All existing `H5Pset_filter` call sites continue to work
- The on-disk format is unchanged (no file format bump)
- The `H5Z_class3_t` struct layout is unchanged

The TOML parser runs at `H5Pappend_filter` call time and is invisible
after that point. `cd_values` are what get stored, passed to filters,
and written to disk — exactly as before.

---

## The One Trade-off: A Dependency

We now vendor tomlc17. It is:
- MIT-licensed
- ~2 000 lines of C17
- Stripped to the inline table + primitive value subset
- Updated as part of the normal HDF5 dependency refresh

The alternative was owning a custom grammar indefinitely.
A published, maintained spec is the better long-term position.

---

## Summary

| | Custom grammar | TOML inline table |
|-|---------------|-------------------|
| Spec ownership | Ours | TOML v1.0.0 (external, stable) |
| Typed values | No (string only) | Yes (int, float, bool, string) |
| Booleans | Bare key hack | `key = true` / `key = false` |
| Nested config | Not supported | Inline table + dotted keys (Blosc, VOL/VFD) |
| Parser | Hand-written | tomlc17 (vendored subset) |
| Accessor API | `H5Zconfig_get_param` (string) | `_get_int`, `_get_double`, `_get_bool`, `_get_str` |
| cd\_values / on-disk | Unchanged | Unchanged |
| Existing call sites | Unchanged | Unchanged |

The switch buys typed values and a stable external spec.
It costs one vendored dependency.
