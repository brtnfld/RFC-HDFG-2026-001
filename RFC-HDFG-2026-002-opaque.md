# RFC-HDFG-2026-002: In-File Binary Opaque Storage for Filter Configuration

**Status:** Draft — Skeleton  
**Author:** M. Scot Breitenfeld (brtnfld@hdfgroup.org)  
**Depends on:** RFC-HDFG-2026-001 (string-based filter configuration)  
**Target release:** TBD  
**Date:** 2026-06-05

---

## 1. Motivation

RFC-HDFG-2026-001 introduced string-based filter configuration (`H5Pappend_filter`,
`H5Z_class3_t`, `set_config`/`get_config` callbacks) and raised the practical
configuration-size limit from 256 `cd_values` elements (~1 KB) to 4096 characters
via `H5Z_CONFIG_STRING_MAX`.  This is sufficient for most filters but not for all.

Two use cases from LibPressio (raised by @robertu94 during the RFC-HDFG-2026-001
community review) remain unaddressed:

### Use Case A — SZ4 JIT compiler (fundamental size limit)

SZ4 features a just-in-time compiler for fast user-defined modules.  When used,
it needs to store pre-processed source code with the dataset — potentially
multi-megabyte.  There is no external dataset to reference; the binary opaque must
travel with the dataset and be recovered on open.  This is a pure size limitation
that `cd_values` and the 4096-byte string limit cannot address.

### Use Case B — ROIBIN-SZ spatial mask (reference to another dataset)

ROIBIN-SZ stores a binary mask indicating which values use lossless compression.
The preferred design is for this mask to live as a user-visible HDF5 dataset,
with only a reference (8 bytes) stored in the filter configuration.  The filter
would dereference the reference at open time to recover the mask.

This requires the filter to hold an `H5F_t *` (or equivalent) at
`set_config`/open time.  The current `H5Z_class3_t` callbacks receive no file
handle.  Use Case B is therefore a **secondary objective** of this RFC; Use
Case A is the primary objective.

---

## 2. Relationship to RFC-HDFG-2026-001

RFC-HDFG-2026-001 adds three **reserved, NULL-initialized** callbacks to
`H5Z_class3_t` and one reserved enum value to `H5Z_params_type_t`:

```c
/* In H5Z_class3_t (H5Zdevelop.h) — added by RFC-HDFG-2026-001 as void*, activated here */
void *write_blob;  /* NULL until this RFC lands */
void *read_blob;   /* NULL until this RFC lands */
void *close_blob;  /* NULL until this RFC lands */

/* In H5Z_params_type_t (H5Zpublic.h) — reserved by RFC-HDFG-2026-001 */
H5Z_PARAMS_BLOB = 2   /* H5Pappend_filter returns H5E_UNSUPPORTED until this RFC */
```

This RFC activates those hooks.  No new struct version (`H5Z_class4_t`) is
required because the callbacks were added to `H5Z_class3_t` before it shipped.

The callback types are defined in §3.3.1.

All three are NULL-able.  When NULL, the library uses default heap-object
(`H5HG`) I/O.  Plugins implement them only when custom on-disk layout is needed
(e.g., alignment requirements for GPU DMA).

---

## 3. Proposed Design

### 3.1 New internal state in `H5Z_filter_info_t`

```c
/* H5Zprivate.h — internal only */
struct H5Z_filter_info_t {
    /* ... existing fields ... */
    void   *aux_data;   /* in-memory copy of the opaque; NULL if none    */
    size_t  aux_size;   /* byte length of aux_data                     */
    haddr_t aux_addr;   /* file address; HADDR_UNDEF until written     */
};
```

### 3.2 `H5O_PLINE_VERSION_3` on-disk format

The current `H5O_PLINE_VERSION_2` per-filter layout:

```
[id:2][flags:2][cd_nelmts:2][cd_values:cd_nelmts×4][name:variable]
```

Version 3 adds a `has_aux` bit after the name and, when set, an 8-byte
`aux_addr`:

```
[id:2][flags:2][cd_nelmts:2][cd_values:cd_nelmts×4][name:variable]
[has_aux:1][aux_addr:8 if has_aux]
```

The opaque bytes are stored at `aux_addr` as an `H5HG` global heap object
(same mechanism used for large variable-length attributes).  The pipeline
message records only the address; the bytes are not inlined.

`H5O_pline_ver_bounds[]` maps `H5F_libver_t` to the pipeline message version.
Files that use `H5Z_PARAMS_BLOB` require at least the version bound that
enables `H5O_PLINE_VERSION_3`.

### 3.3 New public API

```c
/* Append a filter with a large binary (blob) configuration */
herr_t H5Pappend_filter_blob(hid_t plist_id, H5Z_filter_t id,
                              unsigned int flags,
                              const void *buf, size_t size);
```

#### 3.3.1 Blob callback typedefs (activate the reserved fields in `H5Z_class3_t`)

These typedefs are defined in this RFC and replace the `void *` placeholders
reserved in RFC-HDFG-2026-001:

```c
/* Called at H5Dcreate time to write the blob to the file.
 * Returns the file address via addr_out.
 * If NULL, the library uses H5HG_insert (default heap writer). */
typedef herr_t (*H5Z_write_blob_func_t)(hid_t        file_id,
                                        const void  *buf,
                                        size_t       size,
                                        haddr_t     *addr_out);

/* Called at H5Dopen time to read the blob back from the file.
 * Allocates *buf_out; caller frees via close_blob (or free if NULL).
 * If NULL, the library uses H5HG_read (default heap reader). */
typedef herr_t (*H5Z_read_blob_func_t)(hid_t    file_id,
                                       haddr_t  addr,
                                       void   **buf_out,
                                       size_t  *size_out);

/* Called at H5Dclose time to release the in-memory blob buffer.
 * If NULL, the library calls free(). */
typedef herr_t (*H5Z_close_blob_func_t)(void *buf, size_t size);
```

This is the primary creation entry point for Use Case A.  Activating
`H5Z_PARAMS_BLOB` via `H5Pappend_filter` remains reserved; callers use
`H5Pappend_filter_blob` directly.

> **Open question OQ-4** (see §4): whether to also activate
> `H5Pappend_filter(..., H5Z_PARAMS_BLOB, ...)` as a second entry point or
> keep `H5Z_PARAMS_BLOB` perpetually unsupported in `H5Pappend_filter`.

### 3.4 Dataset create / open lifecycle

**Dataset create** (`H5D__create`), after `H5Z_set_local` runs:
1. For each filter with `aux_data != NULL`, call
   `filter->cls->write_blob(file_id, aux_data, aux_size, &aux_addr)` (or the
   default `H5HG` writer if `write_blob` is NULL).
2. Store `aux_addr` in `H5Z_filter_info_t.aux_addr`.
3. Encode the pipeline message at version 3 with the `has_aux`/`aux_addr`
   fields populated.

**Dataset open** (`H5D__open`):
1. Decode the version-3 pipeline message; for each filter with `has_aux`,
   read `aux_addr`.
2. Call `filter->cls->read_blob(file_id, aux_addr, &aux_data, &aux_size)` (or
   the default `H5HG` reader if `read_blob` is NULL).
3. Populate `aux_data`/`aux_size` in `H5Z_filter_info_t`.
4. Call `set_config(aux_data_as_string_or_raw)` so the filter restores its
   internal state.

**Dataset close**:
Call `close_blob(aux_data, aux_size)` (or `free()` if `close_blob` is NULL) and
zero the fields.

### 3.5 Runtime I/O path is unchanged

`H5Z_pipeline` (the hot path for chunk I/O) touches none of this.  The opaque is
config-only, loaded once at open time.  Compression/decompression performance
is unaffected.

---

## 4. Open Questions

These four questions must be resolved before this RFC can be finalized.

### OQ-1 — Parallel I/O write protocol

In a parallel HDF5 job, `H5D__create` is a collective operation.  Which rank(s)
write the opaque?  How is `aux_addr` broadcast to all ranks before the pipeline
message is encoded?

**Options to evaluate:**
- Rank 0 writes; broadcasts `aux_addr` via `MPI_Bcast` before encoding.
- All ranks write independently (only safe if `H5HG` allocation is deterministic
  across ranks, which it is not in general).
- A new collective phase is added between `H5Z_set_local` and pipeline encoding.

**Blocking:** This question must be resolved before any parallel HDF5 use of
opaques is correct.

### OQ-2 — `H5Pencode` / `H5Pdecode` policy

When a DCPL containing a opaque filter is serialized via `H5Pencode`, what is
written?

**Options:**
- **Serialize opaque bytes:** The encoded DCPL includes the opaque bytes inline.
  `H5Pdecode` reconstructs the in-memory opaque without needing the original file.
  Safe; portable; but encoded DCPLs can be large.
- **Serialize file address only:** The encoded DCPL includes only `aux_addr`.
  The DCPL is not self-contained; `H5Pdecode` requires access to the original
  file.  Simpler but fragile.
- **Error:** `H5Pencode` returns an error for DCPLs containing opaque filters.
  Forces callers to handle the case explicitly.

### OQ-3 — h5repack behavior

When h5repack copies a dataset whose filter has a opaque configuration:

**Options:**
- Copy the opaque bytes to the new file (call `write_opaque` on the destination).
  File is self-contained after repack.
- Copy the `aux_addr` reference (only valid if src and dst are the same file or
  the address is meaningful in the new file — generally not the case).
- Call `read_blob` on the source, then `write_blob` on the destination.
  Clean; handles cross-file copies correctly.

The third option is almost certainly correct but requires h5repack to be aware
of `H5O_PLINE_VERSION_3` and the opaque lifecycle.

### OQ-4 — Opaque storage format

Should opaque bytes be stored as a naked `H5HG` global heap object, or as a new
HDF5 object message type?

**`H5HG` (global heap object):**
- Already used for large variable-length attribute data.
- No new message type needed.
- `H5HG` objects have no metadata (no name, no type, no size header beyond
  the heap collection header).  Tools cannot easily identify them as filter opaques.

**New object message type (`H5O_MSG_FILTER_OPAQUE`):**
- Self-describing; h5dump can display it.
- Adds maintenance burden (new message type handler, encode/decode, copy, debug).
- Future-proofs the format if opaques need versioning or typed metadata.

**Recommendation TBD** by this RFC's working group.

---

## 5. Use Case B — Reference to Another H5D Dataset (Secondary Objective)

Use Case B (ROIBIN-SZ) requires the filter to hold a reference to another HDF5
dataset at open time, not just a raw byte buffer.  This is architecturally
distinct from Use Case A and requires a file handle inside `set_config` (or a
new companion callback).

The current `set_config` signature:
```c
herr_t (*set_config)(const char *params, unsigned *flags,
                     size_t *cd_nelmts, unsigned cd_values[],
                     size_t cd_values_size);
```
receives no file handle.  Solving Use Case B therefore requires one of:

1. **`H5Z_get_file_id()`** — a new public function (analogous to the
   `H5Z_get_dxpl()` solution for Issue 2 in RFC-HDFG-2026-001) that returns
   the active file `hid_t` during `set_config` invocation.  This keeps the
   `set_config` signature stable and avoids a new callback.

2. **A new `open_dataset` callback on `H5Z_class3_t`** — called after
   `H5D__open` with a file `hid_t`, giving the filter a chance to dereference
   stored HDF5 object references.  Cleaner separation of concerns than option 1
   but requires an additional NULL-able field (which is cheap since class3 has
   not shipped yet when this RFC is written).

**Recommendation:** Evaluate option 1 first.  `H5Z_get_file_id()` is a
minimal, one-function addition that unblocks the reference use case without
changing any callback signature.  If it proves insufficient (e.g., the filter
needs to hold the `hid_t` past the `set_config` call), adopt option 2.

This use case is **not blocking** for Use Case A.  It may be addressed in a
point release of this RFC or deferred to RFC-HDFG-2026-003.

---

## 6. What Is Explicitly Out of Scope

- Changes to `H5Z_func_t` (the runtime I/O callback) — the hot path is
  unchanged by this RFC.
- Changes to `H5Z_class2_t` or `H5Z_class1_t`.
- Opaque support for group fractal heap filters.
- Multi-file opaque sharing (opaque in file A referenced by dataset in file B).

---

## 7. Files Affected

| File | Change |
|---|---|
| `src/H5Zpublic.h` | Activate `H5Z_PARAMS_BLOB = 2` (remove unsupported note) |
| `src/H5Zdevelop.h` | Replace `void *` placeholders with `H5Z_write_blob_func_t`/`H5Z_read_blob_func_t`/`H5Z_close_blob_func_t` |
| `src/H5Zprivate.h` | Add `aux_data`, `aux_size`, `aux_addr` to `H5Z_filter_info_t` |
| `src/H5Zpkg.h` | Already has opaque callback fields in `H5Z_entry_t` (RFC-HDFG-2026-001) |
| `src/H5Z.c` | Wire up `write_blob`/`read_blob`/`close_blob` in create/open/close paths |
| `src/H5Pocpl.c` | Remove `H5E_UNSUPPORTED` guard; implement `H5Pappend_filter_blob` |
| `src/H5Opline.c` | `H5O_PLINE_VERSION_3` encode/decode with `has_aux`/`aux_addr` |
| `src/H5Dchunk.c` | No changes — hot path is unchanged |
| `tools/src/h5repack/` | Opaque-aware copy (OQ-3) |
| `test/` | New test: create/open/repack with opaque filter |

---

## 8. References

- RFC-HDFG-2026-001: String-Based Filter Configuration API
- LibPressio GitHub comment by @robertu94, HDFGroup/hdf5_plugins#255
  (see `LIBPRESSIO-FEEDBACK.md` in this repository)
- `H5HG.c` — global heap implementation in HDF5 source
- HDF5 issue #6407 — filter registry source-of-truth migration (out of scope)
