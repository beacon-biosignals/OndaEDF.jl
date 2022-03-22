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

Note that callers can additionally use the `labels` argument to `edf_to_onda_signals` to workaround some of these expectations; see the `plan_edf_to_onda_samples` docstring for more details.

## Fine-grained control over `Signal` processing: `plan_edf_to_onda_samples` and `edf_to_onda_samples(edf, plan)`

Because the default labels do not always match EDF files as seen in the wild, OndaEDF provides additional tools for creating, inspecting, manipulating, and recording the `EDF.Signal`-to-`Onda.Samples` mapping.
In fact, the high-level function `edf_to_onda_samples` contains very few lines of code:
```julia
function edf_to_onda_samples(edf::EDF.File; kwargs...)
    signals_plan = plan_edf_to_onda_samples(edf; kwargs...)
    EDF.read!(edf)
    samples, exec_plan = edf_to_onda_samples(edf, signals_plan)
    return samples, exec_plan
end
```
The executed plan as returned is a [Tables.jl](https://github.com/JuliaData/Tables.jl)-compatible table, with one row per `EDF.Signal` and columns for
- the fields of the original `EDF.SignalHeader`
- the fields of the generated `Onda.SamplesInfo`, including
  - `:kind`, the extracted signal kind
  - `:channel`, the extracted channel label (instead of `:channels`, since each `EDF.Signal` is exactly one channel in `Onda.Samples`)
- `:edf_signal_index`, the 1-based numerical index of the source signal in `edf.signals`
- `:onda_signal_index`, the ordinal index of the resulting samples (not necessarily the index into `samples`, since some groups might be skipped)
- `:error`, any errors that were caught during planning and/or execution.

This table could, for instance, be recorded somewhere during ingest of large or complex datasets, as a record of how the `Onda.Samples` were generated.
OndaEDF provides [Legolas.jl Schemas](https://beacon-biosignals.github.io/Legolas.jl/stable/#Legolas-Schemas-and-Rows-1) for this purpose: `Plan` (`"ondaedf.plan@1"`) which corresponds to the columns for a single EDF signal-to-Onda channel conversion, and `FilePlan` (`"ondaedf.file-plan@1"`) which includes the additional file-level linkage columns `:edf_signal_index` and `:onda_signal_index`.
The `write_plan(io_or_path, plan_table)` provides a wrapper around [`Legolas.write`](https://beacon-biosignals.github.io/Legolas.jl/stable/#Legolas.write) which writes a table following the `"ondaedf.file-plan@1"` schema to a generic path-like destination.

It can also be manipulated programmatically, by manually or semi-automatically modifying the `:kind`, `:channel`, or other columns to correct for missed signals by the default labels (for which `:kind` and `:channel` will be `missing`).
We give two examples of how such a workflow might work here: one where the plan is modified before being executed, and another where EDF signal headers are be _preprocessed_ before the plan is constructed.

### Modification of a plan

For instance, some EEG datasets have the physical units set to millivolts, but the signals are usually better measured in microvolts.
During import, you want to correct this by adjusting the encoding settings used by Onda to store samples, by scaling the sample offset and resolution by 1000 and setting the physical units.
This can be accomplished by modifying the rows of the plan like so:

```julia
edf = EDF.File(my_edf_file_path)
plans = plan_edf_to_onda_samples(edf; label=my_labels)

function fix_millivolts(plan)
    if plan.sample_unit == "millivolt" && plan.kind == "eeg"
        sample_resolution_in_unit = plan.sample_resolution_in_unit * 1000
        sample_offset_in_unit = plan.sample_offset_in_unit * 1000
        return Tables.rowmerge(plan; sample_unit="microvolt",
                               sample_resolution_in_unit,
                               sample_offset_in_unit)
    else
        return plan
    end
end

new_plan = map(fix_millivolts, Tables.rows(plans))
samples, plan_executed = edf_to_onda_samples(edf, new_plan)
```

As another, similar example, sometimes EMG channels get recorded with different physical units.
In such a case, OndaEDF will store them with different `kind` values (`emg_1`, `emg_2`, etc.).
This can be corrected in a similar way, for exmaple by converting millivolts to microvolts (adjusting of course depending on the nature of your dataset) and re-grouping into Onda signals:

```julia
edf = EDF.File(my_edf_file_path)
plans = plan_edf_to_onda_samples(edf; label=my_labels)

function fix_emg(plan)
    if startswith(plan.kind, "emg")
        if plan.sample_unit == "millivolt"
            sample_resolution_in_unit = plan.sample_resolution_in_unit * 1000
            sample_offset_in_unit = plan.sample_offset_in_unit * 1000
            plan = Tables.rowmerge(plan; sample_unit="microvolt",
                                   sample_resolution_in_unit,
                                   sample_offset_in_unit)
        end
        return Tables.rowmerge(plan; kind="emg")
    else
        return plan
    end
end

new_plan = map(fix_emg, Tables.rows(plans))
# re-compute the grouping of EDF signals into Onda signals:
new_plan = plan_edf_to_onda_samples_groups(new_plan)
samples, plan_executed = edf_to_onda_samples(edf, new_plan)
```

### Pre-processing signal headers

Sometimes non-standard usage of the label and transducer type fields makes automatic matching difficult.
In such cases, you can _preprocess_ the signal headers before generating a plan.
For example, in a situation where the transducer type and labels are switched, you can switch them back before planning:

```julia
edf = EDF.File(my_edf_file_path)

function corrected_header(signal::EDF.Signal)
    header = signal.header
    return Tables.rowmerge(header; 
                           label=header.transducer_type, 
                           transducer_type=header.label)
end

plans = map(plan_edf_to_onda_samples ∘ corrected_header, edf.signals)
grouped_plans = plan_edf_to_onda_samples_groups(plans)
samples, plan_executed = edf_to_onda_samples(edf, grouped_plans)
```
