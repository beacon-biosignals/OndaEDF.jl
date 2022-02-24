module OndaEDF

using Base.Iterators
using Dates
using EDF
using Legolas
using Onda
using PrettyTables
using StatsBase
using TimeSpans
using Tables
using UUIDs

using Legolas: @row, lift
using Onda: LPCM_SAMPLE_TYPE_UNION, onda_sample_type_from_julia_type, convert_number_to_lpcm_sample_type
using Tables: rowmerge

export write_plan
export edf_to_onda_samples, edf_to_onda_annotations, plan_edf_to_onda_samples, store_edf_as_onda
export onda_to_edf

# can be dropped if we drop Onda<0.14
sample_type(x) = isdefined(Onda, :sample_type) ? Onda.sample_type(x) : x.sample_type

include("standards.jl")

"""
    Plan = @row("ondaedf.plan@1",
                # EDF.SignalHeader fields
                label::String
                transducer_type::String
                physical_dimension::String
                physical_minimum::Float32
                physical_maximum::Float32
                digital_minimum::Float32
                digital_maximum::Float32
                prefilter::String
                samples_per_record::Int16
                # EDF.FileHeader field,
                seconds_per_record::Float64
                # Onda.SamplesInfo fields (channels -> channel), may be missing
                kind::Union{Missing, AbstractString}
                channel::Union{Missing, AbstractString}
                sample_unit::Union{Missing, AbstractString}
                sample_resolution_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION}
                sample_offset_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION}
                sample_type::Union{Missing, AbstractString}
                sample_rate::Union{Missing, LPCM_SAMPLE_TYPE_UNION}
                # errors, use `nothing` to indicate no error
                error::Union{Nothing, String})

A type-alias for a Legolas row describing a single EDF signal-to-Onda channel
conversion.  The columns are the union of
- fields from `EDF.SignalHeader` (all mandatory)
- the `seconds_per_record` field from `EDF.FileHeader` (mandatory)
- fields from `Onda.SamplesInfo` (optional, may be `missing` to indicate failed
  conversion)
- `error`, which is `nothing` for a conversion that is or is expected to be 
  successful, and a `String` describing the source of the error (with backtrace)
  in the case of a caught error.

The [`FilePlan`](@ref) extension contains two columns that give additional
context about the conversion that only apply at the level of an `EDF.File`: 
- `edf_signal_index` gives the index of the source EDF signal
- `onda_signal_index` gives the index of the output `Onda.Samples`.  Note some
  indices may be skipped in the output, so this is only to indicate order and
  grouping.

"""
const Plan = @row("ondaedf.plan@1",
                  # EDF.SignalHeader fields
                  label::String,
                  transducer_type::String,
                  physical_dimension::String,
                  physical_minimum::Float32,
                  physical_maximum::Float32,
                  digital_minimum::Float32,
                  digital_maximum::Float32,
                  prefilter::String,
                  samples_per_record::Int16,
                  # EDF.FileHeader field,
                  seconds_per_record::Float64,
                  # Onda.SamplesInfo fields (channels -> channel), may be missing
                  kind::Union{Missing, AbstractString} = lift(String, kind),
                  channel::Union{Missing, AbstractString} = lift(String, channel),
                  sample_unit::Union{Missing, AbstractString} = lift(String, sample_unit),
                  sample_resolution_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_resolution_in_unit),
                  sample_offset_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_offset_in_unit),
                  sample_type::Union{Missing, AbstractString} = lift(Onda.onda_sample_type_from_julia_type, sample_type),
                  sample_rate::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_rate),
                  # errors, use `nothing` to indicate no error
                  error::Union{Nothing, String} = coalesce(error, nothing))

"""
    const FilePlan = @row("ondaedf.file-plan@1" > "ondaedf.plan@1",
                          edf_signal_index::Int,
                          onda_signal_index::Int)

Type alias for a Legolas row for one EDF signal-to-Onda channel conversion,
which includes the columns of a [`Plan`](@ref) and additional file-level context:
- `edf_signal_index` gives the index of the `signals` in the source `EDF.File` 
  corresponding to this row
- `onda_signal_index` gives the index of the output `Onda.Samples`.

Note that while the EDF index does correspond to the actual index in
`edf.signals`, some Onda indices may be skipped in the output, so
`onda_signal_index` is only to indicate order and grouping.
"""
const FilePlan = @row("ondaedf.file-plan@1" > "ondaedf.plan@1",
                      edf_signal_index::Int,
                      onda_signal_index::Int)

"""
    write_plan(io_or_path, plan_table; validate=true, kwargs...)

Write a plan table to `io_or_path` using `Legolas.write`, using the
`ondaedf.file-plan@1` schema.
"""
function write_plan(io_or_path, plan_table; kwargs...)
    return Legolas.write(io_or_path, plan_table,
                         Legolas.Schema("ondaedf.file-plan@1");
                         kwargs...)
end

include("import_edf.jl")

include("export_edf.jl")

end # module
