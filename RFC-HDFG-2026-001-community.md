# RFC-HDFG-2026-001: String-Based Filter Configuration API

**Author:** Scot Breitenfeld (HDF Group)  
**Date:** 2026-05-11  
**Status:** Draft for Community Review  
**Full RFC:** RFC-HDFG-2026-001 (tagged `v1.0-full`)

---

## Summary

This RFC proposes a human-readable string interface for configuring HDF5 I/O
filters. The existing `H5Pset_filter` API requires callers to construct raw
arrays of `unsigned int` (`cd_values`), which is error-prone, opaque at the
command line, and essentially unusable from Python without a per-filter wrapper.
The new API accepts TOML-style `key = value` strings. Everything existing
continues to work unchanged.

---

## Problem

**Type punning for floating-point parameters.** Filters like H5Z-ZFP accept
`double` parameters. Callers must manually bit-cast the value into `unsigned int`
slots — a process that is endian-sensitive and impossible to express naturally
from Python:

```c
unsigned int cd_vals[4];
double rate = 3.5;
cd_vals[0] = H5Z_ZFP_MODE_RATE;
memcpy(&cd_vals[2], &rate, sizeof(double));
H5Pset_filter(plist, H5Z_FILTER_ZFP, flags, 4, cd_vals);
```

In Python this requires `struct.pack` and knowledge of ZFP's internal layout.
Every binding reimplements this independently and differently.

**Opaque CLI.** `h5repack` users pass raw integer sequences
(`-f UD=32013,0,4,1,0,0,1074921472`) and rely on external scripts to generate
them.

**Opaque introspection.** The `cd_values` array in a file is meaningless without
consulting the filter's documentation. There is no standard way to recover
"ZFP rate mode, rate=3.5" from stored integers.

---

## What's New

### New API function: `H5Pappend_filter`

```c
herr_t H5Pappend_filter(hid_t plist_id, H5Z_filter_t id,
                         unsigned flags, const H5Z_params_t *params);
```

`H5Z_params_t` is a tagged union: pass a string or existing `cd_values`.
Two macros cover the common cases:

```c
/* String form */
H5Pappend_filter(plist, H5Z_FILTER_DEFLATE, H5Z_FLAG_MANDATORY,
                 &H5Z_PARAMS_STR("level = 6"));

H5Pappend_filter(plist, H5Z_FILTER_ZFP, H5Z_FLAG_MANDATORY,
                 &H5Z_PARAMS_STR("mode = \"rate\", rate = 3.5"));

/* Blosc2 with sub-compressor parameters */
H5Pappend_filter(plist, H5Z_FILTER_BLOSC, H5Z_FLAG_MANDATORY,
                 &H5Z_PARAMS_STR("compressor.name = \"zlib\", "
                                 "compressor.level = 6, shuffle = 1"));

/* Parameterless filter */
H5Pappend_filter(plist, H5Z_FILTER_SHUFFLE, H5Z_FLAG_MANDATORY, NULL);

/* Raw cd_values — identical to H5Pset_filter */
unsigned level = 6;
H5Pappend_filter(plist, H5Z_FILTER_DEFLATE, H5Z_FLAG_MANDATORY,
                 &H5Z_PARAMS_RAW(1, &level));
```

> **Note:** With a string parameter, the plugin is loaded and `set_config` is
> called immediately. A missing plugin returns an error at `H5Pappend_filter`
> rather than at `H5Dcreate`.

### New API function: `H5Pget_filter_params_by_idx`

Returns the human-readable parameter string for a filter in the pipeline.
For filters that implement `get_config`, that output is used; otherwise the raw
`cd_values` are formatted as a fallback (`"cd_values=1:0:0:1074921472"`).

---

## Parameter String Format

The format is a subset of **TOML v1.0.0 inline table syntax**, parsed by a
vendored subset of the MIT-licensed tomlc17 library. This gives the library
typed values and a stable, externally maintained specification.

Outer braces are optional — the library accepts both:

```
level = 6                    (bare form)
{level = 6}                  (braced form; equivalent)
```

| Parameter String | Use Case |
|-----------------|----------|
| `level = 6` | deflate (integer) |
| `mode = "rate", rate = 3.5` | ZFP (string + float) |
| `pixels_per_block = 16, coding = "entropy"` | SZIP |
| `scale_type = "float_dscale", scale_factor = 4` | scale-offset |
| `fast_mode = true, level = 6` | boolean flag |
| `path = "/data/run_1,v2/dict.bin"` | string value containing a comma |
| `compressor.name = "zlib", compressor.level = 6, shuffle = 1` | Blosc2 sub-compressor (dotted keys) |
| `compressor = {name = "zlib", level = 6}, shuffle = 1` | Blosc2 sub-compressor (inline table; equivalent) |
| `NULL` | no parameters (shuffle, fletcher32) |

**Value types:** integer, float, boolean (`true`/`false`), double-quoted string,
nested inline table, dotted keys.  
**Constraints:** 4096 byte maximum, 64 top-level key maximum, C-locale decimal
separator, `filter_title` is reserved.

---

## Built-in Filter Parameters

All built-in filters implement the string API out of the box.

| Filter | Example parameter string |
|--------|--------------------------|
| Deflate | `level = 6` (integer 0–9) |
| Shuffle | `NULL` |
| Fletcher32 | `NULL` |
| SZIP | `coding = "entropy", pixels_per_block = 8` |
| N-Bit | `NULL` (parameters derived from datatype) |
| Scale-Offset | `scale_type = "float_dscale", scale_factor = 4` |

---

## For Plugin Authors

Upgrading is **optional**. Existing v2 plugins continue to work without any
changes.

To opt in, register with `H5Z_class3_t` instead of `H5Z_class2_t`. It adds
two optional callbacks and an optional `filter_title` label:

```c
typedef struct H5Z_class3_t {
    int                    version;       /* H5Z_CLASS3_T_VERS */
    H5Z_filter_t           id;
    unsigned               encoder_present;
    unsigned               decoder_present;
    const char            *name;          /* canonical plugin name, e.g. "zfp" */
    const char            *filter_title;  /* display label, e.g. "ZFP Compression" */
    H5Z_can_apply_func_t   can_apply;
    H5Z_set_local_func_t   set_local;
    H5Z_func_t             filter;
    H5Z_set_config_func_t  set_config;   /* string → cd_values (optional) */
    H5Z_get_config_func_t  get_config;   /* cd_values → string (optional) */
} H5Z_class3_t;
```

**`set_config`** receives the parameter string and fills `cd_values`.
Typed accessor helpers (declared in `H5Zdevelop.h`) handle parsing:

```c
static herr_t
my_set_config(const char *params, unsigned *flags,
              size_t *cd_nelmts, unsigned cd_values[], size_t cd_values_size)
{
    int64_t level = 6;
    if (params)
        H5Zconfig_get_int(params, "level", &level);

    *cd_nelmts = 1;
    if (cd_values)
        cd_values[0] = (unsigned)level;
    return SUCCEED;
}
```

Available accessors: `H5Zconfig_get_int`, `H5Zconfig_get_double`,
`H5Zconfig_get_bool`, `H5Zconfig_get_str`. Dotted keys
(`"compressor.level"`) reach into nested inline tables.

**`get_config`** reconstructs a parameter string from `cd_values` for
`h5dump -p` output and `H5Pget_filter_params_by_idx`. Optional but recommended.

**`filter_title`** is a short human-readable label stored in `cd_values` so
tools can display it even when the plugin is not installed.

> **Compatibility note:** Because `filter_title` adds trailing slots to
> `cd_values`, any plugin that validates `cd_nelmts == expected` (exact equality)
> will fail on files written by a v3 registration. Use `cd_nelmts >= expected`
> instead. This guidance is already in the HDF5 developer documentation.

---

## CLI Changes

### h5repack

Old syntax continues to work. New syntax accepts a filter name and parameter
string:

```bash
# Old (unchanged)
h5repack -f 'UD=32013,0,4,1,0,0,1074921472' in.h5 out.h5

# New — filter name + TOML parameter string
h5repack -f 'zfp, mode = "rate", rate = 3.5' in.h5 out.h5
h5repack -f 'deflate, level = 9' in.h5 out.h5
```

### h5dump

`h5dump -p` appends a `PARAMS_STRING` line per filter. Default output is
unchanged.

```
FILTERS {
  COMPRESSION DEFLATE { LEVEL 6 }
  PARAMS_STRING "level = 6"
}
```

---

## Compatibility

| Area | Status |
|------|--------|
| `H5Pset_filter` and all existing APIs | Unchanged; no deprecation |
| Existing v1/v2 plugins | Work without modification |
| On-disk format | No change — files are byte-identical to `H5Pset_filter` output |
| Files from `H5Pappend_filter` | Readable by all existing HDF5 readers |
| ABI | New functions added; no existing signatures changed |
| h5py, PyTables, netCDF4-Python | No changes required |
| Fortran and Java bindings | Updated to expose the new functions |

A future RFC (targeting HDF5 3.0) will explore typed on-disk parameter storage.
The `H5Z_cd_pack_*` packing convention introduced here is designed as its
foundation; filters that adopt it now will be forward-compatible.

---

## Questions for Community Feedback

1. **`filter_title` and `cd_nelmts` compatibility.** Should `filter_title` be
   opt-in at the call site so a v3 plugin can ship string support without
   changing the on-disk `cd_values` layout until callers explicitly request it?

2. **Nested parameters for wrapping filters.** The design explicitly supports
   Blosc-style filters that embed a sub-compressor (e.g.,
   `compressor.name = "zlib", compressor.level = 6`). Does this meet the needs
   of filters in your community that wrap another codec?

3. **Pipeline-string API.** A single-string pipeline form
   (`"shuffle; deflate, level = 9; fletcher32"`) is deferred. Is there demand
   to include it in this release?

4. **Parallel HDF5 / heterogeneous clusters.** On clusters mixing CPU
   architectures, floating-point string parsing (`strtod`) may produce different
   bit patterns per rank, causing `cd_values` divergence. The recommended
   workaround is to parse on one rank, encode the DCPL with `H5Pencode`,
   broadcast, and decode with `H5Pdecode`. Is this guidance sufficient?

5. **Plugin adoption path.** What documentation or tooling would best lower
   the barrier for third-party plugin authors to adopt `H5Z_class3_t`?
