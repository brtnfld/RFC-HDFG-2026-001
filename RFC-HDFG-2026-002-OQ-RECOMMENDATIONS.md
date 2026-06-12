# RFC-HDFG-2026-002 — Open Question Recommendations

**Author:** M. Scot Breitenfeld  
**Date:** 2026-06-10  
**Status:** Pre-discussion draft  

These recommendations are grounded in how the HDF5 library currently handles
analogous situations.  Each OQ cites the relevant source locations.

---

## OQ-1 — Parallel I/O Write Protocol

**Question:** In a parallel HDF5 job, which rank writes the opaque heap object?
How is `aux_addr` synchronized before the pipeline message is encoded?

### Finding

`H5HG_insert` (`src/H5HG.c:471`) has **zero MPI awareness**.  It allocates
file space and dirties the metadata cache entry directly.  In a parallel
`H5D__create`, if all ranks call `H5HG_insert` with the same opaque bytes,
each rank creates a separate heap object at a different address — there is no
mechanism to agree on a single `aux_addr` for the pipeline message.

This is unlike object-header message appends (`H5O_msg_append_oh`), where the
metadata cache layer (`H5AC`) coordinates collective I/O across ranks.
`H5HG_insert` is a raw file-space allocation, outside the metadata cache
coherency mechanism.

`H5D__create` itself already has a parallel guard for storage allocation
(`src/H5Dint.c:1353`):

```c
if (H5F_HAS_FEATURE(file, H5FD_FEAT_HAS_MPI) && pline.nused == 0)
    alloc_time = H5D_ALLOC_TIME_EARLY;
```

The opaque write phase needs its own parallel guard.

### Recommendation: Rank 0 writes, broadcast `H5HG_t` before encoding

```c
H5HG_t hobj;  /* addr + idx, ~12-16 bytes */

if (H5F_HAS_FEATURE(file, H5FD_FEAT_HAS_MPI)) {
    int mpi_rank;
    MPI_Comm_rank(H5F_mpi_get_comm(file), &mpi_rank);
    if (mpi_rank == 0)
        H5HG_insert(file, aux_size, aux_data, &hobj);
    /* encode addr and idx into a fixed-size buffer for broadcast */
    MPI_Bcast(&hobj.addr, sizeof(haddr_t), MPI_BYTE, 0, comm);
    MPI_Bcast(&hobj.idx,  sizeof(size_t),  MPI_BYTE, 0, comm);
} else {
    H5HG_insert(file, aux_size, aux_data, &hobj);
}
aux_addr = hobj.addr;
/* all ranks now share the same aux_addr; proceed to encode pipeline message */
```

This is the standard HDF5 pattern for "single-writer allocations" in parallel
(e.g., how `H5FD_mpio` coordinates superblock writes).  Only one heap object
is created; all ranks receive its address before the pipeline message is
encoded collectively.

**Implication for `H5Pappend_filter_blob`:** Calling this function on a
parallel open file is legal but must be followed by a collective
`H5D__create`.  If the DCPL is created before the file open (the common
pattern), the broadcast happens inside `H5D__create`, invisible to the caller.

---

## OQ-2 — `H5Pencode` / `H5Pdecode` Policy

**Question:** When a DCPL containing an opaque-config filter is serialized via
`H5Pencode`, what is written?

### Finding

`H5P__ocrt_pipeline_enc` (`src/H5Pocpl.c:1268`) encodes filter ID, flags,
name, and `cd_values` — all purely in-memory data.  No file addresses appear
in the encoded DCPL today.

Fill-value encoding (`src/H5Ofill.c`) follows the same pattern: encode the
in-memory bytes, not a file address.  The principle is that a serialized
property is **self-contained** — it must survive being written to a buffer,
passed across a process boundary, or decoded without the original file.

`aux_addr` is a derived, file-specific value.  `aux_data` is the canonical
in-memory representation.

### Recommendation: Serialize `aux_data` bytes inline; `aux_addr` = `HADDR_UNDEF` on decode

Extend `H5P__ocrt_pipeline_enc` to append, after each filter's `cd_values`:

```
[has_aux:1][aux_size:8 if has_aux][aux_data:aux_size bytes if has_aux]
```

On `H5P__ocrt_pipeline_dec`, read those fields back into `aux_data`/`aux_size`
and set `aux_addr = HADDR_UNDEF`.  When the decoded DCPL is used in a
subsequent `H5D__create`, `write_opaque` fires and assigns a real `aux_addr`
in the new file.

**Tradeoffs:**
- Encoded DCPLs with multi-MB opaque configs will be large.  This is
  acceptable: `H5Pencode` is not a hot path and callers invoking it on a
  DCPL with multi-MB filter config know they have unusual data.
- Serializing `aux_addr` instead would make the encoded DCPL non-portable
  (only valid in the originating file).  This would break every
  `H5Pdecode`-then-`H5D__create` workflow.  **Do not do this.**
- Returning an error for opaque-bearing DCPLs is unnecessarily restrictive;
  `aux_data` is always available in memory after `H5D__open` or after
  `H5Pappend_filter_blob`.

---

## OQ-3 — h5repack Behavior

**Question:** When h5repack copies a dataset whose filter has an opaque
configuration, how does the opaque travel from source to destination file?

### Finding

`h5repack_copy.c:910` uses `H5Pcopy(dcpl_in)` for the normal (non-external)
dataset path.  It does not call `H5HG` functions directly; it works entirely
through the public DCPL API.

The lifecycle that makes h5repack work automatically:

1. `H5Dopen` on source → `read_opaque` callback (or default `H5HG_read`)
   → `aux_data` populated in the filter's `H5Z_filter_info_t` inside `dcpl_in`.
2. `H5Pcopy(dcpl_in)` → must deep-copy `aux_data` bytes into `dcpl_out`
   (see implementation note below).
3. `H5Dcreate` with `dcpl_out` in destination file → `write_opaque` (or
   default `H5HG_insert`) fires → new heap object at a new `aux_addr` in the
   destination file.
4. `aux_addr` is stored in the destination pipeline message.  Source
   `aux_addr` is not copied — only the bytes travel.

### Recommendation: No h5repack code changes needed — fix `H5Pcopy` deep copy

The design is correct **if and only if** `H5Pcopy` performs a deep copy of
`aux_data`.  The existing `H5P__ocrt_pipeline_copy` callback must be extended
to `malloc` + `memcpy` the `aux_data` buffer for each filter that has one.

Specifically, in the `H5O_pline_t` copy path (`src/H5Opline.c`):

```c
/* copy aux_data if present */
if (src_filter->aux_size > 0 && src_filter->aux_data != NULL) {
    dst_filter->aux_data = H5MM_malloc(src_filter->aux_size);
    H5MM_memcpy(dst_filter->aux_data, src_filter->aux_data, src_filter->aux_size);
    dst_filter->aux_size = src_filter->aux_size;
    dst_filter->aux_addr = HADDR_UNDEF;  /* destination address not yet known */
}
```

With this in place, h5repack's `H5Pcopy` path automatically handles the
cross-file copy without any h5repack-specific code.

**Edge case — h5repack removes or replaces a filter:** When `apply_filters()`
removes a filter from `dcpl_out`, the pipeline `delete` callback must free
`aux_data`.  This is a standard property cleanup obligation; implement a
`H5O_pline_reset`-style destructor that checks and frees `aux_data`.

---

## OQ-4 — Opaque Storage Format: `H5HG` vs New Message Type

**Question:** Should opaque bytes be stored as a naked `H5HG` global heap
object, or as a new HDF5 object message type (`H5O_MSG_FILTER_OPAQUE`)?

### Finding

`H5HG_insert` (`src/H5HG.c:471`) takes a raw buffer and size and returns an
`H5HG_t` reference (heap collection address + object index, ~12-16 bytes).
There is no embedded type metadata — the bytes are opaque by definition.

A new object message type (`H5O_msg_class_t`, `src/H5Opkg.h:210`) requires
at minimum: `decode`, `encode`, `copy`, `raw_size`, `reset`, `free`, `del`,
`link`, `pre_copy_file`, `copy_file`, `post_copy_file` — approximately 13
callbacks, plus a reserved message-type ID in the HDF5 format specification.

The argument **for** a new message type is tooling: h5dump could identify the
object as "filter opaque config for filter X."  The argument **against** is
that even with a new message type, the content is filter-plugin-specific
binary data that h5dump cannot render meaningfully.  The pipeline message
(`H5O_PLINE_VERSION_3`) already provides the "which filter" context via filter
ID.

Vlen/blob data (`src/H5VLnative_blob.c:59`) uses `H5HG` for the same
pattern: large binary object, reference stored in the object header, retrieved
on demand.  This is the established HDF5 precedent.

### Recommendation: Naked `H5HG` for initial implementation

Store the opaque bytes as a raw `H5HG` object.  Store the encoded `H5HG_t`
reference (addr + idx) in `H5O_PLINE_VERSION_3` as `aux_addr` (split into
`aux_addr` and `aux_idx` fields, or packed as a blob ID following the
`H5VLnative_blob.c` encoding).

**Rationale:**

1. **Precedent.** Vlen blob data uses `H5HG`.  The HDF5 format already has a
   well-understood mechanism for "large binary thing referenced from object
   header."

2. **Tooling value is low.** A new message type would display
   `"FILTER_OPAQUE: 4 MB of SZ4 JIT source"` in h5dump.  That is marginally
   better than nothing, but the content is still not human-readable.  The
   existing pipeline message already names the filter.

3. **Maintenance cost.** 13 callbacks × forever is a significant ongoing
   burden for marginal tooling gain.  New message types have historically been
   added only when the stored data has a stable, interpretable schema (fill
   values, datatypes, dataspaces).

4. **Escape hatch.** If the tooling need becomes clear after deployment, a
   `H5O_MSG_FILTER_OPAQUE` can be introduced in a later file-format version
   without breaking existing files.  The `H5O_PLINE_VERSION_3` bump is already
   required for `has_aux`; a future version can reinterpret the `aux_addr`
   field as a typed reference.

**`del` callback obligation:** When a pipeline message is deleted (dataset
deleted, filter removed), `H5HG_remove(file, &hobj)` must be called to reclaim
the heap space.  This is implemented in the pipeline message `delete` handler
in `src/H5Opline.c`, analogous to how the fill-value message's `delete`
handler frees vlen data (`src/H5Ofill.c:113`).

---

## Summary Table

| # | Question | Recommendation | Key Source Analogy |
|---|---|---|---|
| OQ-1 | Parallel write | Rank 0 inserts into `H5HG`; `MPI_Bcast` `H5HG_t` before pipeline encoding | `H5FD_mpio` single-writer pattern |
| OQ-2 | `H5Pencode` policy | Serialize `aux_data` bytes inline; `aux_addr = HADDR_UNDEF` on decode | Fill-value property encoding (`H5Ofill.c`) |
| OQ-3 | h5repack | No h5repack changes; fix `H5Pcopy` to deep-copy `aux_data`; `write_opaque` fires on dest `H5D__create` | `H5P__ocrt_pipeline_copy` |
| OQ-4 | Storage format | Naked `H5HG`; `del` handler calls `H5HG_remove` | Vlen blob via `H5VLnative_blob.c` |
