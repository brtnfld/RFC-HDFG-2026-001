# RFC-HDFG-2026-001 — Technical Review Findings

Reviewed against the HDF5 `develop` branch at
`/home/brtnfld_2025/brtnfld/packages/hdf5` on 2026-04-23.

Legend:  **F** = factual error (clearly wrong against current code);
**I** = internal inconsistency between sections; **C** = clarification needed
(technically defensible but will mislead readers); **V** = verified correct (no
action). Severity: **H** high, **M** medium, **L** low.

---

## F1 [H] — `H5Pset_filter` **appends duplicates**; it does not replace

**Where:** `sections/architecture.tex` §Public API (`H5Pset_filter2`),
line block starting “If a filter with the same ID is already present in the
pipeline, it is replaced (not duplicated)—this matches the existing behavior
of `H5Pset_filter`.”
Also R18 in `sections/resolved.tex`.

**Evidence:**
- `src/H5Pocpl.c:595` → `H5Pset_filter` → `H5P__set_filter` →
  `src/H5Pocpl.c:674` calls `H5Z_append`.
- `src/H5Z.c:1180–1275` `H5Z_append` unconditionally appends; it does not
  search for an existing entry with the same ID.
- The de-dup / replace behavior lives in `H5Z_modify`
  (`src/H5Z.c:1115–1177`), which is reached only via `H5Pmodify_filter`
  (`src/H5Pocpl.c:~480`), not `H5Pset_filter`.

**Why it matters:** the RFC promises that `H5Pset_filter2` and
`H5Pset_filter` are *fully interchangeable on the same DCPL* and that both
“replace” when called twice with the same ID. Today calling `H5Pset_filter`
twice for the same filter ID yields two identical filter entries in the
pipeline. The RFC must either (a) specify that `H5Pset_filter2` replaces
(an intentional divergence from `H5Pset_filter`) and describe the semantic
difference, or (b) have `H5Pset_filter2` append-duplicate to match. The
current “matches existing behavior” wording is false either way.

---

## F2 [H] — `H5F_LIBVER_V200` already exists; it is `LATEST` today

**Where:** `sections/architecture.tex` §`H5Pset_libver_bounds` Integration,
the `#define H5F_LIBVER_V200 5 /* HDF5 2.0 -- introduces H5O_PLINE_VERSION_3 */`
minted block. Also implicitly in §Write Conditions, §Fallback Behavior,
§Compatibility (On-Disk Format).

**Evidence:**
- `src/H5Fpublic.h:180–188`: `H5F_LIBVER_V200 = 5`, `H5F_LIBVER_LATEST = 5`
  (i.e. `LATEST == V200`), already shipped in `develop`.
- `src/H5Opline.c:85–93` `H5O_pline_ver_bounds[]` maps
  `H5F_LIBVER_V200 → H5O_PLINE_VERSION_2`, and
  `H5F_LIBVER_LATEST → H5O_PLINE_VERSION_LATEST` (also `= 2`).

**Why it matters:** the RFC introduces `V200` as a “version constant
introduced by this feature.” It is not. Two fixes to pick from:

1. **Do not introduce a new libver constant.** Instead, change the mapping:
   `H5O_pline_ver_bounds[H5F_LIBVER_V200] = H5O_PLINE_VERSION_3`, and bump
   `H5O_PLINE_VERSION_LATEST` to 3. This only works if HDF5 2.0 has not
   yet released with the current mapping — otherwise V200 files in the
   wild assume VERSION_2 and the change is a silent format re-mapping.
2. **Introduce a new libver constant** (e.g. `H5F_LIBVER_V210`) whose
   mapping entry in `H5O_pline_ver_bounds` is `H5O_PLINE_VERSION_3`, and
   keep `V200 → VERSION_2` byte-stable. This is the safer, more additive
   path and matches the HDF5 convention of one libver per release series.

Either way, the decision and its rationale must be stated explicitly.
Quietly reusing `V200` obscures the question.

---

## F3 [M] — `H5PL__open` does **not** read the `version` field via `memcpy`

**Where:** `sections/architecture.tex` §Version Numbering, “The library
reads the `version` field in `H5Zregister()` and `H5PL__open` via `memcpy`
through a `char *` to avoid strict-aliasing undefined behaviour.”

**Evidence:** `src/H5PLint.c:318–477` (`H5PL__open`) resolves plugins by
looking up the per-plugin symbols `H5PLget_plugin_type` and
`H5PLget_plugin_info` via `H5PL_GET_LIB_FUNC` and invoking them. It never
inspects a raw struct prefix. The `memcpy`-through-`char*` technique
applies to `H5Zregister()` (where the caller hands in a typed pointer);
`H5PL__open` receives already-typed results from the plugin’s own
exported functions.

**Fix:** drop “and `H5PL__open`” from that sentence, or restate as
“`H5Zregister()` inspects the `version` field via `memcpy` through a
`char *` to avoid strict-aliasing UB; `H5PL__open` receives an already
typed pointer from the plugin’s `H5PLget_plugin_info` and does not need
this.”

---

## F4 [M] — Built-in filter `name` fields are **already short canonical names**, not verbose prose

**Where:** `sections/testing.tex` §Semantic Change and §Migration guidance,
“Before (v2): freeform debug comment … Existing plugins commonly populate
this field with human-readable prose such as ‘HDF5 ZFP filter, version
1.0.0 (rate, precision, and accuracy modes)’ or ‘My Compression
Library v2.3’.” Also reg-04a (expects a verbose v2 name string).

**Evidence (built-ins all use bare canonical names):**

Updated to reflect RFC-HDFG-2026-001 implementation: all built-ins have been
upgraded to `H5Z_class3_t` with the same short canonical names retained and
new `description` fields added.  The SZIP name `”szip”` was confirmed correct
via the GitHub issue #255 community discussion (@mkitti noted `”szip (libaec)”`
informally but the canonical name proposal remained `”szip”`); see also
`BUILTIN-FILTER-NAMES.md` in this repository.

| Filter | `H5Z_class3_t.name` | File |
|---|---|---|
| deflate | `”deflate”` | `src/H5Zdeflate.c` |
| shuffle | `”shuffle”` | `src/H5Zshuffle.c` |
| fletcher32 | `”fletcher32”` | `src/H5Zfletcher32.c` |
| szip | `”szip”` | `src/H5Zszip.c` |
| nbit | `”nbit”` | `src/H5Znbit.c` |
| scaleoffset | `”scaleoffset”` | `src/H5Zscaleoffset.c` |

**Why it matters:** the RFC’s migration narrative is built on the premise
that migrating v2 → v3 moves verbose prose from `name` into `description`
so `H5Pget_filter2` output stays informative. For HDF5’s own built-ins the
“before” and “after” `name` values will be identical (`”deflate”`,
`”shuffle”`, …). The migration of built-ins will consist of *adding* a
`description` field, not “moving text” out of `name`. Third-party plugins
vary; some do use verbose strings (H5Z-ZFP, BLOSC2 historically), but the
blanket claim that v2 plugins “commonly” carry verbose prose is an
overgeneralization.

**Status:** evidence confirmed; RFC text fix still needed.

**Fix:** reword §Semantic Change to:
- Acknowledge that *some* v2 plugins (including several popular
  third-party filters) use verbose names and rely on them being surfaced
  via `H5Pget_filter2`.
- Acknowledge that all HDF5 built-in filters already use short
  canonical-style names; their upgrade to v3 is semantically trivial.
- Amend reg-04a to use a known third-party-style example (or a synthetic
  test plugin with a verbose name), not to claim this is the common case.

---

## I1 [H] — Abstract still advertises `H5Pset_filter_by_name`; §5 and R32 use `H5Pset_filter2`

**Where:** `sections/abstract.tex` — “The proposed design introduces
`H5Pset_filter_by_name`, which accepts a filter name and a human-readable
key=value parameter string.”

**Conflict:** R32 in `sections/resolved.tex` records the decision to ship
`H5Pset_filter2` (ID-based + string params), *not* a name-based API;
`sections/architecture.tex` §`sec:set-filter2` defines the ID-based
signature. The abstract is stale.

**Fix:** rewrite the abstract to describe `H5Pset_filter2(plist, id,
flags, params)` and drop the by-name phrasing.

---

## I2 [M] — Plugin discovery described as “extends VFD/VOL by-name search in H5PL” in abstract; R7/R11 say loading is strictly by integer ID

**Where:**
- `sections/abstract.tex`: “Name-based plugin discovery extends the
  existing VFD/VOL by-name search pattern in the H5PL module.”
- `sections/resolved.tex` R7: “Plugin loading is always by integer ID;
  the name registry is display-only and does not trigger plugin loading.”
- R11: same.

**Fix:** drop the “name-based plugin discovery” sentence from the
abstract. Replace with: “The library maintains an internal name→ID
registry populated at library initialization and via v3-plugin
self-registration. Plugin loading itself remains by integer ID; the
registry is used by `h5repack` to translate canonical names to IDs
before the call to `H5Pset_filter2`.”

---

## I3 [M] — `H5Pget_filter_name_by_idx` referenced after being dropped (R1)

**Where:**
- R1: “A name-by-index variant (`H5Pget_filter_name_by_idx`) was
  considered but dropped …”
- R23 (in `resolved.tex`) still refers to `H5Pset_filter_by_name`.
- §Thread Safety: “all access to the registry — including lookups during
  `H5Pget_filter_name_by_idx`”.
- §Test Plan `ts-01`, `ts-02`: “call `H5Pget_filter_name_by_idx`”.
- R36: “Both `H5Pget_filter_name_by_idx` (canonical name) and
  `H5Pget_filter_params_by_idx` (parameter string) are retained.” —
  contradicts R1.

**Fix:** pick one. If `H5Pget_filter_name_by_idx` is truly dropped (R1 is
current), rewrite §Thread Safety, ts-01, ts-02, and R36 to refer only to
`H5Pget_filter_params_by_idx` and to internal registry lookups performed
by `h5repack`. If it is retained (R36), restore its specification in
§Public API and reconcile R1.

---

## I4 [L] — R23 still references `H5Pset_filter_by_name`

**Where:** `sections/resolved.tex` R23: “inspect the error stack after
`H5Pset_filter_by_name` returns”.

**Fix:** change to `H5Pset_filter2`.

---

## C1 [M] — R26 (h5repack `UD=` digit-precedence rule) is incompatible with the architecture-section rule that `UD` is a *forbidden* canonical filter name

**Where:**
- `sections/architecture.tex` §CLI §`UD=` disambiguation: “`UD` is a
  **forbidden** canonical filter name and is rejected by the name
  registry … The h5repack parser always treats `UD=` as the legacy
  syntax.”
- `sections/resolved.tex` R26: “if the text following `UD=` begins with
  a decimal digit, the specification is parsed as the legacy syntax;
  otherwise it is treated as new-syntax where `UD` is a registered
  canonical filter name.”

**Conflict:** the architecture section says `UD` can never be a canonical
name; R26 assumes it can. R26 appears to be stale.

**Fix:** retire R26 or rewrite it to match the forbidden-name rule
(which is simpler and has no ambiguity). I recommend matching the
architecture section.

---

## C2 [M] — `H5O_pline_ver_bounds[]` already exists; the RFC should describe its update, not a new gating mechanism

**Where:** `sections/architecture.tex` §`H5Pset_libver_bounds`
Integration: “The existing libver-bounds enforcement in
`H5O__pline_encode` is extended: before writing a filter entry with
non-UINT32 slot types, the encoder queries the file’s upper bound.”

**Evidence:** the mapping is table-driven in
`src/H5Opline.c:85–93`. The version is chosen by
`H5O_pline_set_version` (`src/H5Opline.c:~700–718`) with
`MAX(pline->version, H5O_pline_ver_bounds[H5F_LOW_BOUND(f)])` and a
range check against `[H5F_HIGH_BOUND(f)]`. No per-encode query is
needed; the change is one row of the bounds table plus bumping
`H5O_PLINE_VERSION_LATEST`.

**Fix:** describe the actual change:
1. Add `H5O_PLINE_VERSION_3 = 3` and bump `H5O_PLINE_VERSION_LATEST`
   (see F2 for the V200-vs-new-libver question).
2. Update the row of `H5O_pline_ver_bounds[]` for the chosen libver
   upper bound to map to `VERSION_3`.
3. Have `set_config` callbacks advance `pline->version` to
   `VERSION_3` when they emit typed slots; `H5O_pline_set_version` will
   then reject the write if the file’s high bound doesn’t allow it
   (or, per RFC §Fallback, downgrade to VERSION_2 and warn — note that
   this conflicts with the existing behavior, which *errors* when the
   desired version exceeds the bound; explicit design choice needed).

---

## C3 [L] — “First-registered-wins” for name collisions is silently-wrong for overrides

**Where:** §Plugin Auto-Registration. “If a name is already present …
the later registration is silently ignored — first registration wins.”

**Consideration:** this is a defensible choice but deserves a note:
applications that *intentionally* load a newer ZFP plugin over an older
one will find the registry still points to the older. Since the
registry is used for `h5repack` name→ID resolution only, and the same
canonical name should always resolve to the same numeric ID (per
process requirement §Filter names in the HDF Group registry), this is
fine in practice. Recommend adding one sentence: “Because canonical
names correspond to unique numeric IDs in the HDF Group registry,
‘first-registered-wins’ is benign: the name always resolves to the
correct ID regardless of which binary registered the plugin first.”

---

## C4 [L] — Two-pass `set_config` “identity contract” has an edge case worth documenting

**Where:** §Callback Specifications, “Two-pass identity contract.”

**Consideration:** the contract says `cd_nelmts` is identical on both
passes. That is clean, but the template immediately after (§Canonical
set_config) then notes “filters that wish to avoid this overhead may …
skip the size-query pass by always reporting the maximum count, filling
unused slots with a sentinel value.” The sentinel approach is called out
as *conforming*. Two concerns:

1. Sentinels in `cd_values` are stored on disk and in the DCPL. Every
   downstream reader must tolerate them (the filter itself can, but
   `H5Pget_filter2`, `h5dump -p`, and third-party tools see the padding
   too).
2. With VERSION_3 type tags, sentinel UINT32 slots will be tagged
   `H5Z_SLOT_UINT32`; consumers won’t know they’re padding.

Recommend either: forbid sentinels when emitting VERSION_3
(`H5O_PLINE_VERSION_3` slots must carry semantically meaningful data),
or define a `H5Z_SLOT_PAD` tag. Not a blocker, but the current text
makes the two approaches equivalent when they aren’t.

---

## C5 [L] — `H5Pget_filter2` return-semantics change for v3 plugins is an API-behavior change that deserves louder signposting

**Where:** §Backward Compatibility (architecture §`sec:class3`) and
§Compatibility (testing §name-semantic-change). The RFC correctly
notes this but frames it as “preserved display role.”

**Observation:** for a v3 plugin with `description = NULL`, existing
callers that `printf`-ed the v2 `name` now get the canonical
identifier (possibly shorter than before). That’s an observable
change. The current text says “may constitute an API behavioral change
even if the function signature is unchanged.” Consider upgrading from
“may constitute” to “is” and cross-referencing a migration note that
plugin authors MUST populate `description` to preserve the v2
contract. This matters for HDF5 built-ins too: they currently surface
`"deflate"`, `"shuffle"`, etc., which *are* already short. After
conversion to v3, those same strings will be returned via
`description` (recommended) or `name`. Outcome is unchanged as long as
the conversion sets `description` equal to the old `name` or leaves it
`NULL` to fall back to `name`. This should be explicitly shown in the
implementation-section note on the built-ins.

---

## V — Verified correct (no action)

- V1. `H5Z_CLASS_T_VERS = 1`, `H5Z_class_t_vers` compat macro default
  `= 2`, new `H5Z_CLASS3_T_VERS = 2` is a non-conflicting add-in.
  (`src/H5Zdevelop.h:31`, `src/H5version.h:1681,1683`.)
- V2. Three-way dispatch in `H5Zregister()` (and two-way under
  `H5_NO_DEPRECATED_SYMBOLS`) is consistent with current
  `src/H5Z.c:250–272` logic.
- V3. `H5Z_filter_info_t` field layout as quoted.
  (`src/H5Zprivate.h:52–60`.)
- V4. `H5Z_MAX_NFILTERS = 32` (enforced in `H5Z_append`,
  `src/H5Z.c:1206–1207`).
- V5. `H5Z_COMMON_CD_VALUES = 4`, `H5Z_COMMON_NAME_LEN = 12`
  (`src/H5Zprivate.h:41,45`).
- V6. `cd_nelmts` on-disk is `UINT16`; `UINT16_MAX` cap is therefore
  correct (`src/H5Opline.c:327`).
- V7. `H5O_PLINE_VERSION_1 = 1`, `…_2 = 2`, `_LATEST = 2` today
  (`src/H5Oprivate.h:741,747,751`).
- V8. `H5Pset_driver_by_name(fapl, name, config)` exists as public
  API since 1.14 (`src/H5Ppublic.h:4434`); no `H5Pset_vol_by_name`;
  `H5VLregister_connector_by_name` and `H5VLget_connector_id_by_name`
  exist (`src/H5VLpublic.h:242,346`).
- V9. `H5Pset_szip` behavior — every bullet (encoder check, pixel
  validation, K13/RAW masks, chip/LSB/MSB stripping, unconditional
  `H5Z_FLAG_OPTIONAL`) is verified against `src/H5Pdcpl.c:2879–2930`.
- V10. `H5Pset_deflate` valid levels `0..9`, default 6, goes through
  `H5Z_append` (`src/H5Pocpl.c:1044–1074`).
- V11. `H5Pset_scaleoffset` encodes `scale_type` and `scale_factor`
  into a 2-slot `cd_values` (`src/H5Pdcpl.c:3036–3079`) — matches the
  RFC’s built-in §Scale-Offset encoding.
- V12. h5repack `-f` legacy syntax (`GZIP`, `SZIP`, `SHUF`, `FLET`,
  `NBIT`, `SOFF`, `NONE`, `UD=`) and the `path:filter` separator are
  as described (`tools/src/h5repack/h5repack_parse.c:18–38, 219–241`).
- V13. h5dump FILTERS block today has no `PARAMS_STRING`
  (`tools/lib/h5tools_dump.c:3542–3700`). Addition is a genuine
  extension.
- V14. `H5Zfilter_avail(H5Z_filter_t)` — ID-only — is the current
  public API (`src/H5Z.c:708`).

---

## Priority recommendation

1. **Fix F1, F2, F3** before sending the RFC to external review —
   these are flat-out wrong and will be caught immediately by HDF5
   engineers. F1 in particular changes a user-visible semantic.
2. **Resolve I1, I2, I3** — the abstract and the design decisions
   record contradict each other; reviewers will lose trust.
3. **Reword F4** to narrow the claim to third-party plugins; acknowledge
   the built-in case.
4. **Rewrite C2** to describe the actual `H5O_pline_ver_bounds[]` and
   `H5O_pline_set_version` mechanism — the current text invents a
   mechanism that isn’t there.
5. The remaining items (C1, C3–C5, I4) are editorial polish.
