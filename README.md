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

## Fine-grained control over `Signal` processing: `plan` and `execute_plan`

Because the default labels do not always match EDF files as seen in the wild, OndaEDF provides additional tools for creating, inspecting, manipulating, and recording the `EDF.Signal`-to-`Onda.Samples` mapping.
In fact, the high-level function `edf_to_onda_samples` contains very few lines of code:
```julia
function edf_to_onda_samples(edf::EDF.File; kwargs...)
    signals_plan = plan(edf; kwargs...)
    EDF.read!(edf)
    samples, exec_plan = execute_plan(signals_plan, edf)
    return samples, exec_plan
end
```
The executed plan as returned is a Tables.jl compatible table, with one row per EDF.Signal and columns for
- the fields of the original `EDF.SignalHeader`
- the fields of the generated `Onda.SamplesInfo`, including
  - `:kind`, the extracted signal kind
  - `:channel`, the extracted channel label (instead of `:channels`, since each `EDF.Signal` is exactly one channel in `Onda.Samples`)
- `:edf_signal_idx`, the numerical index of the source signal in `edf.signals`
- `:onda_signal_idx`, the ordinal index of the resulting samples (not necessarily the index into `samples`, since some groups might be skipped)
- `:error`, any errors that were caught during planning and/or execution.

This table could, for instance, be recorded somewhere during ingest of large or complex datasets, as a record of how the `Onda.Samples` were generated.

It can also be manipulated programmatically, by manually or semi-automatically modifying the `:kind`, `:channel`, or other columns to correct for missed signals by the default labels (for which `:kind` and `:channel` will be `missing`).
