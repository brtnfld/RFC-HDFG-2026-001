# LibPressio GitHub Feedback — H5Z Limitations

**Source:** GitHub comment by @robertu94 (LibPressio author), via HDFGroup/hdf5_plugins#255  
**Context:** Response to RFC-HDFG-2026-001 community review

---

## Original Comment

> Hi @brtnfld, Thank you for your effort on this. I'm the author of LibPressio that @lindstro mentioned. I found out about this via HDFGroup/hdf5_plugins#255 when my colleague @disheng222 got an email about it. If HDF5 is looking at changes to the H5Z subsystem, there are some more changes to consider that may inform your design. These thoughts come from implementing a HDF5 Filter for LibPressio, which made me intimately aware of some of the limitations of the current H5Z_class2_t.
>
> Some compressors have large (multi-megabyte) configuration values, which cause segfaults when attempting to store in CD values over a few KB. For example, ROIBIN-SZ, stores a binary "mask" indicating which values the compressors should use lossless compression for. The SZ team is currently working on SZ4, which features a just-in-time compiler for fast user-defined modules, which, when used, needs to store pre-processed source code. In the first case, ideally, the compressor could have access to another H5D dataset, so only a reference is needed (but this makes updating the filter much harder because we can't access the underlying H5F or H5G objects). In the other case, there is just a fundamental size limitation that needs to be addressed.

---

## Issue 1 — Large Configuration Values

Two distinct sub-cases:

### Sub-case A: ROIBIN-SZ (mask stored in another H5D dataset)
The binary mask indicating which values use lossless compression ideally lives as a user-visible H5D dataset, with only an HDF5 object reference (8 bytes) stored in the filter config. The filter then dereferences it at open time.

**Blocker:** Filters cannot access `H5F` or `H5G` objects — the `H5Z_func_t` callback and `set_local` receive no file handle.

**Does the in-file opaque design solve this?**  
Only partially. The opaque design *can* store the mask bytes directly in the file as a heap object (self-contained). But that is a different tradeoff from what robertu94 wants:

| | Opaque stores mask bytes | Reference to H5D dataset |
|---|---|---|
| File self-contained | Yes | Yes (if in same file) |
| User can inspect/update mask via HDF5 tools | No | Yes |
| Filter needs `H5F`/`H5G` handle at runtime | No | Yes |
| In-file opaque design solves it | Yes (as bytes) | No |

Solving the reference case requires passing an `H5F_t *` into `set_config` or adding a new lookup callback — a separate design question not addressed by this RFC.

### Sub-case B: SZ4 JIT compiler (pre-processed source code)
This is a pure size limitation — there is no external dataset to reference; the compiled/preprocessed source simply needs to be stored somewhere large enough to travel with the dataset.

**Does the in-file opaque design solve this?**  
**Yes, directly.** The pre-processed source is a large byte buffer. With `H5Z_PARAMS_OPAQUE`:

1. Filter's `set_config` (or user via `H5Z_PARAMS_OPAQUE`) passes pointer + length.
2. Library writes it to a heap object in the file via `write_opaque`; stores `aux_addr` in the `H5O_PLINE_VERSION_3` pipeline message.
3. On dataset open, `read_opaque` retrieves the bytes; `set_config` restores the JIT state.
4. File is self-contained.

---

## Issue 2 — Non-Serializable Runtime Settings

Filters like LibPressio need access to non-serializable, process-local handles at I/O time (e.g., `MPI_Comm`, `cudaStream_t`, resolution/quality parameters per-read).

**Solution (in scope for this RFC):** Expose `H5Z_get_dxpl()` — a single public function wrapping the internal `H5CX_get_dxpl()`, which already returns the active DXPL `hid_t` during any I/O operation. Filter plugins use `H5Pinsert2`/`H5Pregister2` to store handles in the DXPL before I/O, then retrieve them via `H5Z_get_dxpl()` + `H5Pget()` inside `H5Z_func_t`.

---

## Issue 3 — Chunk Position / Coordinates

Filters need to know which chunk they are operating on (e.g., for spatially-aware compression, or for routing work to specific GPU tiles).

**Solution (in scope for this RFC):** The scaled chunk coordinates (`scaled[]`) are already present at every `H5Z_pipeline` call site in `H5Dchunk.c` but are not forwarded into the pipeline. Adding them to `H5Z_class3_t` via a new optional callback or extending `H5Z_func_t` passes this information with no file-format impact.

---

## In-File Opaque Design Summary

Five interlocking pieces:

1. **`H5Z_PARAMS_OPAQUE = 2`** — reserved enum value; `H5Pappend_filter` returns `H5E_UNSUPPORTED` until activated.
2. **`H5Z_filter_info_t` new fields** — `aux_data` (void *), `aux_size` (size_t), `aux_addr` (haddr_t).
3. **Three new NULL-able callbacks on `H5Z_class3_t`** — `write_opaque`, `read_opaque`, `close_opaque`; file handle `H5F_t *` passed internally, never exposed to end-user code.
4. **`H5O_PLINE_VERSION_3`** — adds `has_aux` bit + `aux_addr` per filter to the on-disk pipeline message; opaque bytes stored as a heap object (`H5HG`) at `aux_addr`.
5. **New phases in `H5D__create` / `H5D__open`** — `write_opaque` called on create, `read_opaque` on open, `close_opaque` on close.

The hot path (`H5Z_pipeline` during chunk I/O) is unchanged.

### Four open questions before full activation

1. **Parallel I/O protocol** — which rank writes the opaque; how to avoid races on `aux_addr`.
2. **`H5Pencode`/`H5Pdecode` policy** — serialize opaque bytes or file address?
3. **h5repack behavior** — copy opaque bytes or call `write_opaque` again?
4. **Opaque storage format** — naked `H5HG` heap object vs. new message type.

The callbacks are added to `H5Z_class3_t` now as NULL fields (zero cost). Full `H5Z_PARAMS_OPAQUE` support deferred pending resolution of the four open questions.
