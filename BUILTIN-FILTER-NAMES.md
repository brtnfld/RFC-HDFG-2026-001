# Built-in Filter Canonical Names

Canonical `name` field values assigned to the HDF5 built-in filters when they
were upgraded to `H5Z_class3_t` as part of RFC-HDFG-2026-001.

| Filter ID constant | Numeric ID | `name` field |
|---|---|---|
| `H5Z_FILTER_DEFLATE` | 1 | `"deflate"` |
| `H5Z_FILTER_SHUFFLE` | 2 | `"shuffle"` |
| `H5Z_FILTER_FLETCHER32` | 3 | `"fletcher32"` |
| `H5Z_FILTER_SZIP` | 4 | `"szip"` |
| `H5Z_FILTER_NBIT` | 5 | `"nbit"` |
| `H5Z_FILTER_SCALEOFFSET` | 6 | `"scaleoffset"` |

These names are short, lowercase, and stable — the same strings written into
the filter-pipeline message's name slot on disk (for third-party-range filter
IDs) and used by `h5repack` for name-based filter lookup once that feature
is activated (RFC-HDFG-2026-001 §4.7).
