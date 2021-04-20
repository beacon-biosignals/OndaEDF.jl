# OndaEDF.jl

[![CI](https://github.com/beacon-biosignals/OndaEDF.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/beacon-biosignals/OndaEDF.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/beacon-biosignals/OndaEDF.jl/branch/master/graph/badge.svg?token=7oZhx7P9kq)](https://codecov.io/gh/beacon-biosignals/OndaEDF.jl)
[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://beacon-biosignals.github.io/OndaEDF.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://beacon-biosignals.github.io/OndaEDF.jl/dev)

OndaEDF provides functionality to convert/import/export EDF files to/from Onda recordings; see the `edf_to_onda_samples`, `edf_to_onda_annotations`, and `onda_to_edf` docs/tests for details.

## EDF Formatting Expectations

While OndaEDF attempts to be somewhat robust to more common nonstandard/noncompliant quirks that often appear in EDF files "in the wild", the package generally expects the caller to perform any necessary preprocessing to their EDFs to ensure they comply with the EDF/EDF+ standards/specifications, as well as a few other expectations to facilitate conversion to Onda.

These expectations are as follows:

- `EDF.Signal` labels follow the standard "$TYPE $SPECIFICATION" structure defined by [the EDF standards](https://www.edfplus.info/specs/edftexts.html), and signal types documented by the aforementioned standard (EEG, EKG, etc.) are labeled in compliance with naming conventions defined by the standard.
- `EDF.Signal`s that are matched as channels to a common `Onda.Signal` must have the same `physical_dimension`, sample rate, and sample count.
- The `physical_dimension` field for any given `EDF.Signal` is a value supported by `OndaEDF.STANDARD_UNITS`.

Note that callers can additionally use the `custom_extractors` argument to `edf_to_onda_signals` to workaround some of these expectations; see the `import_edf` docstring for more details.
