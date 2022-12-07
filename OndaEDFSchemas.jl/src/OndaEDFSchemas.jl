module OndaEDFSchemas

using Legolas: Legolas, @schema, @version, lift
using Onda: LPCM_SAMPLE_TYPE_UNION, onda_sample_type_from_julia_type, convert_number_to_lpcm_sample_type

export PlanV1, PlanV2, FilePlanV1, FilePlanV2

@schema "ondaedf.plan" Plan

@version PlanV1 begin
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
    # EDF.FileHeader field
    seconds_per_record::Float64
    # Onda.SamplesInfoV1 fields (channels -> channel), may be missing
    kind::Union{Missing,AbstractString} = lift(String, kind)
    channel::Union{Missing,AbstractString} = lift(String, channel)
    sample_unit::Union{Missing,AbstractString} = lift(String, sample_unit)
    sample_resolution_in_unit::Union{Missing,LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_resolution_in_unit)
    sample_offset_in_unit::Union{Missing,LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_offset_in_unit)
    sample_type::Union{Missing,AbstractString} = lift(onda_sample_type_from_julia_type, sample_type)
    sample_rate::Union{Missing,LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_rate)
    # errors, use `nothing` to indicate no error
    error::Union{Nothing,String} = coalesce(error, nothing)
end

@version PlanV2 begin
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
    # EDF.FileHeader field
    seconds_per_record::Float64
    # Onda.SamplesInfoV2 fields (channels -> channel), may be missing
    sensor_type::Union{Missing,AbstractString} = lift(String, sensor_type)
    sensor_label::Union{Missing,AbstractString} = lift(String, sensor_type)
    channel::Union{Missing,AbstractString} = lift(String, channel)
    sample_unit::Union{Missing,AbstractString} = lift(String, sample_unit)
    sample_resolution_in_unit::Union{Missing,Float64}
    sample_offset_in_unit::Union{Missing,Float64}
    sample_type::Union{Missing,AbstractString} = lift(onda_sample_type_from_julia_type, sample_type)
    sample_rate::Union{Missing,Float64}
    # errors, use `nothing` to indicate no error
    error::Union{Nothing,String} = coalesce(error, nothing)
end

const PLAN_DOC = """
    @version PlanV\$N begin
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
        # EDF.FileHeader field
        seconds_per_record::Float64
        # Onda.SamplesInfo fields (channels -> channel), may be missing
        kind::Union{Missing,AbstractString}
        channel::Union{Missing,AbstractString}
        sample_unit::Union{Missing,AbstractString}
        sample_resolution_in_unit::Union{Missing,LPCM_SAMPLE_TYPE_UNION}
        sample_offset_in_unit::Union{Missing,LPCM_SAMPLE_TYPE_UNION}
        sample_type::Union{Missing,AbstractString}
        sample_rate::Union{Missing,LPCM_SAMPLE_TYPE_UNION}
        # errors, use `nothing` to indicate no error
        error::Union{Nothing,String}
    end

A type-alias for a Legolas row describing a single EDF signal-to-Onda channel
conversion.  The columns are the union of
- fields from `EDF.SignalHeader` (all mandatory)
- the `seconds_per_record` field from `EDF.FileHeader` (mandatory)
- fields from `Onda.SamplesInfo` (optional, may be `missing` to indicate failed
  conversion)
- `error`, which is `nothing` for a conversion that is or is expected to be
  successful, and a `String` describing the source of the error (with backtrace)
  in the case of a caught error.

Differences between versions are:
- `PlanV1` has a `kind` field, whereas in `PlanV2` this has been renamed `sensor_type`.
"""

@doc PLAN_DOC PlanV1
@doc PLAN_DOC PlanV2

@schema "ondaedf.file-plan" FilePlan

@version FilePlanV1 > PlanV1 begin
    edf_signal_index::Int
    onda_signal_index::Int
end

@version FilePlanV2 > PlanV2 begin
    edf_signal_index::Int
    onda_signal_index::Int
end

const FILE_PLAN_DOC = """
    @version FilePlanV\$N > PlanV\$N begin
        edf_signal_index::Int
        onda_signal_index::Int
    end

Type alias for a Legolas row for one EDF signal-to-Onda channel conversion,
which includes the columns of a [`PlanV1`](@ref) or [`PlanV2`](@ref) and additional file-level context:
- `edf_signal_index` gives the index of the `signals` in the source `EDF.File`
  corresponding to this row
- `onda_signal_index` gives the index of the output `Onda.Samples`.

Note that while the EDF index does correspond to the actual index in
`edf.signals`, some Onda indices may be skipped in the output, so
`onda_signal_index` is only to indicate order and grouping.
"""

@doc FILE_PLAN_DOC FilePlanV1
@doc FILE_PLAN_DOC FilePlanV2

end # module
