# RFC-HDFG-2026-001 — Weaknesses & Risks Review

Reviewed against `RFC-HDFG-2026-001-ai.md` (2026-04-24) and cross-checked
against `REVIEW-FINDINGS.md` and `FUTURE-typed-cd-values-impl-plan.md`.

---

## Weaknesses & Risks

### Plugin Authors Must Handle Locale-Safe Float Parsing

The RFC requires `set_config` callbacks that parse floating-point parameters
to use C-locale numeric conversion — in practice `strtod` under
`uselocale(newlocale(LC_NUMERIC_MASK, "C", 0))`, or "a locale-independent
equivalent." The phrase "or a locale-independent equivalent" is the key:
`uselocale` is POSIX-specific and Windows requires
`_strtod_l(str, &end, _C_LOCALE)` instead.  The RFC acknowledges the
requirement but delegates the cross-platform implementation entirely to plugin
authors, while providing no library helper to bridge the gap.

A plugin author who writes plain `strtod(val_buf, &end)` on a German or
French locale workstation will silently misparse `"rate=3.5"` as `"rate=3"` —
the comma-decimal locale splits the string at the comma that the library's
own parser has already consumed.  The bug surfaces only at runtime on
locale-affected machines, not in US-locale CI.

Note that only floating-point parameters are affected.  Integer parameters —
which cover all six built-in HDF5 filters (deflate level, SZIP pixels per
block, etc.) — use `strtol`/`strtoul`, which are locale-independent.  The
at-risk population is third-party plugin authors implementing filters with
float rate/tolerance parameters (ZFP, BLOSC2, etc.).

### The Two-Pass Callback Contract: Documented but Fragile for Third Parties

The `set_config` two-pass requirement (identical `cd_nelmts` on both passes)
is a subtle protocol.  The RFC provides a canonical template implementation,
extensive documentation, and two enforcing test cases (cb-02, cb-03).  An
escape hatch exists: callbacks can always report the worst-case `cd_nelmts`
on the first pass and fill unused slots with a sentinel value, skipping the
size-query protocol entirely.  These mitigations are appropriate for an
in-house implementation but still leave third-party plugin authors at risk of
subtle bugs — particularly any callback that makes `cd_nelmts` depend on
environment state or external configuration.

One gap worth noting: if locale state changes between the two passes (possible
in a multi-threaded application modifying locale from a second thread),
floating-point parsing may produce a different count on the second pass.  This
is an unlikely but valid failure mode for float-parameterized filters.

### Non-ASCII Bytes in Quoted Values: Allowed But Underdocumented

The original version of this review claimed the RFC restricts file paths to
ASCII.  **That claim is incorrect.**  The RFC states explicitly: "Within
quoted values, any byte sequence is accepted verbatim (the parser does not
interpret character encoding inside quotes)."  The parameter
`dict_path="/path/to/my/dictionary_über.bin"` is legal under the grammar; the
library passes the raw byte sequence to the filter callback.

The residual risk is discoverability.  The header of the character-encoding
section ("Parameter strings are restricted to printable ASCII") creates a
false impression that quoted values share this restriction.  Plugin authors who
read only that sentence may incorrectly reject or mangle non-ASCII input.  The
fix is documentation only: add an explicit note in `H5Zdevelop.h` that values
returned by `H5Zconfig_get_param` for quoted parameters may contain non-ASCII
bytes and that path-accepting callbacks should treat them as opaque byte strings.

### String Length Limit

`H5Z_CONFIG_STRING_MAX = 4096` bytes is generous for current use cases.
Near-future filters — ML-specific compressors that embed quantization schemas
or references to auxiliary config files inline — may exceed this.  The
challenge with bumping to 65536 bytes is stack allocation: if parser work
buffers are stack-allocated at `H5Z_CONFIG_STRING_MAX` size (common in
embedded deployments), 64 KB is significant.  A more targeted fix is to move
parser work buffers to heap allocation for strings longer than a threshold,
which allows raising or eliminating the cap without affecting the typical case.

---

## HDF5-Specific Architectural Feedback

**VOL and VFD Integration:** Flawless.  Because `H5Pset_filter2` translates
strings to `cd_values` eagerly, VFDs and VOLs see standard HDF5 filter
pipelines.  No VOL callbacks (`H5VL_dataset_create`, etc.) need modification.

**Parallel I/O (MPI) / DCPL Consistency:** The RFC correctly notes that
parsing happens independently on all MPI ranks.  Eagerly failing in
`H5Pset_filter2` if a plugin is missing is the right choice.  The
float-determinism concern on heterogeneous clusters is addressed under
"Unaddressed Edge Cases" below.

**Single-Writer/Multiple-Reader (SWMR):** Since string configuration happens
at DCPL creation — well before data is flushed or datasets are exposed to
readers — this RFC introduces zero risk to SWMR operations.

**Memory vs. On-Disk Endianness:** The packing convention (`H5Z_SLOT_DBL_LO`,
`H5Z_SLOT_DBL_HI`) correctly forces little-endian storage in memory arrays,
aligning with HDF5's internal `cd_values` endianness guarantees.  The
`H5Z_cd_pack_double` helpers perform the necessary byte swap on big-endian
hosts (e.g., IBM zSystems), which is critical for correctness.

---

## Unaddressed Edge Cases

### 1. Heterogeneous MPI Cluster DCPL Mismatch

In a Parallel HDF5 application on a mixed-architecture cluster (x86_64 +
ARM64), all ranks execute `H5Pset_filter2("zfp", "rate=3.55555555")`.  If the
`strtod` implementations on x86_64 and ARM64 are not both correctly-rounded
per IEEE 754, they will produce different bit patterns for the same decimal
string.  The two ranks then pack different `double` values into `cd_values`.
When `H5Dcreate` is called collectively, HDF5 detects the DCPL mismatch and
fails.

The `H5Z_cd_pack_double` helper guarantees consistent bit layout *once a
`double` is in hand*; it does not help if `strtod` returns different values on
different architectures.  The RFC's `par-01` test verifies DCPL consistency
but only on homogeneous deployments.  The recommended mitigation — broadcast
the DCPL from a single root rank, or `MPI_Bcast` the parameter string before
all ranks call `H5Pset_filter2` — should be explicitly documented.

### 2. Built-in Name Protection: Implicit, Not Explicit

Built-in names (`"deflate"`, `"szip"`, etc.) are registered at `H5open()`,
before any user plugin loads, so first-registered-wins protects them in
practice.  However, the RFC does not explicitly declare these names as
permanently reserved.  A reader cannot tell from the spec whether an unusually
early `dlopen` before `H5open` could inject a plugin claiming a built-in name.
The fix is a one-sentence normative guarantee: the six built-in canonical
names and the reserved token `UD` cannot be claimed by plugin auto-registration
regardless of registration order.

### 3. Filter Deletion / Unregistration Race (Pre-Existing)

`H5Zunregister` now also removes all name registry entries for the unregistered
filter ID.  In thread-safe builds, if chunk I/O is in flight on a dataset
using that filter, the filter function pointer could be dereferenced after the
registry entry has been freed.  This is a pre-existing HDF5 limitation — not
introduced by this RFC — but the new name registry cleanup step in
`H5Zunregister` is a new touchpoint that reinforces the pre-existing hazard.

### 4. Libver Constant Naming Inconsistency — Architectural Risk

**This risk is not discussed in the current RFC.**  The RFC uses
`H5F_LIBVER_V200` in the Write Conditions and Fallback Behavior sections to
gate `H5O_PLINE_VERSION_3` output, but defines and uses `H5F_LIBVER_V300` in
the `H5Pset_libver_bounds` Integration section, the Compatibility section, and
the test plan (`reg-05`).  These are different constant names applied to the
same gate condition within the same document.

`H5F_LIBVER_V200` already exists in `H5Fpublic.h` (value = 5) and currently
maps `H5O_pline_ver_bounds[V200]` to `H5O_PLINE_VERSION_2`.  If the RFC ships
using this existing constant to gate version-3 output, the `V200` row in
`H5O_pline_ver_bounds[]` must change — silently reclassifying all existing
V200 files so that a library that called
`H5Pset_libver_bounds(fapl, ..., H5F_LIBVER_V200)` expecting version-2
pipeline messages now produces version-3 messages unreadable by pre-RFC
readers.  This is a silent backward-compatibility break.

The safe path is to introduce a **new** constant (`H5F_LIBVER_V210` or
`H5F_LIBVER_V300`) and add a new row to `H5O_pline_ver_bounds[]` mapping it
to `H5O_PLINE_VERSION_3`, leaving the V200 row unchanged.  See also
REVIEW-FINDINGS.md §F2 (High).

---

## Actionable Recommendations

### 1. Provide a Library-Level Numeric Parsing Helper

Do not force plugin authors to handle locale masking.  Expose
`H5Zconfig_parse_double(const char *str, double *val)` and
`H5Zconfig_parse_int64(const char *str, int64_t *val)` in `H5Zdevelop.h`.
HDF5 already has internal, cross-platform, locale-agnostic string parsing
macros; wrapping them closes the Windows/POSIX locale gap and completes the
plugin author's toolkit alongside `H5Zconfig_get_param` (key lookup) and
`H5Z_cd_pack_double` (encoding).

### 2. Explicitly Reserve Built-in Names in the Registry Specification

Add a normative sentence to the Filter Name Registry section: the six
built-in canonical names (`deflate`, `szip`, `shuffle`, `fletcher32`, `nbit`,
`scaleoffset`) and the reserved token `UD` are permanently reserved and are
rejected by plugin auto-registration regardless of registration order.  This
converts an implicit implementation property into an explicit spec guarantee.

### 3. Add a Parallel Float-Determinism Warning

Explicitly document in the Parallel HDF5 section that parameter strings
containing floating-point values (e.g., `"rate=3.55"`) may produce different
`cd_values` on heterogeneous architectures due to `strtod` implementation
differences.  Recommend that applications on mixed-architecture clusters
broadcast the DCPL from a single root rank after `H5Pset_filter2` rather than
having each rank independently parse the string.  `H5Z_cd_pack_double` is
layout-deterministic but only after the `double` value has been obtained; the
string-to-double conversion step is not guaranteed to be bit-identical across
all platforms.

### 4. Resolve the Libver Constant Naming Inconsistency

Audit all uses of `H5F_LIBVER_V200` and `H5F_LIBVER_V300` throughout the RFC
and implementation plan and converge on a single name.  Given that
`H5F_LIBVER_V200` already exists in the codebase and maps to
`H5O_PLINE_VERSION_2`, introduce a new constant for the version-3 gate —
preferably `H5F_LIBVER_V300` if this feature ships with HDF5 3.0, or
`H5F_LIBVER_V210` for an intermediate 2.x release.  Update
`H5O_pline_ver_bounds[]` by adding a new row for the chosen constant without
modifying the existing V200 row.

### 5. Reconsider H5Z_CONFIG_STRING_MAX Bump Strategy

Rather than unconditionally raising the cap from 4096 to 65536 bytes, move
parser work buffers to heap allocation for strings longer than a threshold
(e.g., 512 bytes).  This preserves stack safety on embedded targets while
allowing complex configurations to grow without a fixed ceiling.  If a simple
bump is preferred, use heap allocation unconditionally in the parser and
document the allocation behavior in `H5Zdevelop.h`.

---

## Change Log

| Item | Change from original review |
|---|---|
| "ASCII-Only String Restriction" | Rewritten — original claim was factually wrong; RFC allows non-ASCII inside quoted values via "any byte sequence accepted verbatim" |
| "Explicitly Allow UTF-8" recommendation | **Removed** — already present in the RFC; no grammar change needed |
| Locale section | Scoped to float parameters only; integer parameters (all six built-ins) are not affected by locale |
| Two-pass trap | Added note about the explicit escape hatch already present in the RFC |
| Libver constant inconsistency | **New item** — cross-reference REVIEW-FINDINGS.md §F2 (High) |
| Built-in name protection | Promoted from passing mention to explicit edge case and recommendation |
| String length recommendation | Revised — 65536-byte stack allocation is non-trivial; recommend heap-allocated parser instead |
