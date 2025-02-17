module OndaEDFSchemas

using Legolas: Legolas, @schema, @version, lift
using Onda: LPCM_SAMPLE_TYPE_UNION, onda_sample_type_from_julia_type,
            convert_number_to_lpcm_sample_type, _validate_signal_channel,
            _validate_signal_sensor_label, _validate_signal_sensor_type,
            AnnotationV1
using UUIDs

export PlanV1, PlanV2, PlanV3, FilePlanV1, FilePlanV2, FilePlanV3, EDFAnnotationV1

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
    # Onda.SignalV1 fields (channels -> channel), may be missing
    recording::Union{UUID,Missing} = lift(UUID, recording)
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
    # Onda.SignalV2 fields (channels -> channel), may be missing
    recording::Union{UUID,Missing} = lift(UUID, recording)
    sensor_type::Union{Missing,AbstractString} = lift(_validate_signal_sensor_type, sensor_type)
    sensor_label::Union{Missing,AbstractString} = lift(_validate_signal_sensor_label,
                                                       coalesce(sensor_label, sensor_type))
    channel::Union{Missing,AbstractString} = lift(_validate_signal_channel, channel)
    sample_unit::Union{Missing,AbstractString} = lift(String, sample_unit)
    sample_resolution_in_unit::Union{Missing,Float64}
    sample_offset_in_unit::Union{Missing,Float64}
    sample_type::Union{Missing,AbstractString} = lift(onda_sample_type_from_julia_type, sample_type)
    sample_rate::Union{Missing,Float64}
    # errors, use `nothing` to indicate no error
    error::Union{Nothing,String} = coalesce(error, nothing)
end

@version PlanV3 begin
    # EDF.SignalHeader fields
    label::String
    transducer_type::String
    physical_dimension::String
    physical_minimum::Float32
    physical_maximum::Float32
    digital_minimum::Float32
    digital_maximum::Float32
    prefilter::String
    samples_per_record::Int32
    # EDF.FileHeader field
    seconds_per_record::Float64
    # Onda.SignalV2 fields (channels -> channel), may be missing
    recording::Union{UUID,Missing} = lift(UUID, recording)
    sensor_type::Union{Missing,AbstractString} = lift(_validate_signal_sensor_type, sensor_type)
    sensor_label::Union{Missing,AbstractString} = lift(_validate_signal_sensor_label,
                                                       coalesce(sensor_label, sensor_type))
    channel::Union{Missing,AbstractString} = lift(_validate_signal_channel, channel)
    sample_unit::Union{Missing,AbstractString} = lift(String, sample_unit)
    sample_resolution_in_unit::Union{Missing,Float64}
    sample_offset_in_unit::Union{Missing,Float64}
    sample_type::Union{Missing,AbstractString} = lift(onda_sample_type_from_julia_type, sample_type)
    sample_rate::Union{Missing,Float64}
    # errors, use `nothing` to indicate no error
    error::Union{Nothing,String} = coalesce(error, nothing)
end

const PLAN_DOC_TEMPLATE = """
    @version PlanV{{ VERSION }} begin
        # EDF.SignalHeader fields
        label::String
        transducer_type::String
        physical_dimension::String
        physical_minimum::Float32
        physical_maximum::Float32
        digital_minimum::Float32
        digital_maximum::Float32
        prefilter::String
        samples_per_record::{{ SAMPLES_PER_RECORD_TYPE }}
        # EDF.FileHeader field
        seconds_per_record::Float64
        # Onda.SignalV{{ VERSION }} fields (channels -> channel), may be missing
        recording::Union{UUID,Missing} = passmissing(UUID)
{{ SAMPLES_INFO_UNIQUE_FIELDS }}
        channel::Union{Missing,AbstractString}
        sample_unit::Union{Missing,AbstractString}
        sample_resolution_in_unit::Union{Missing,Float64}
        sample_offset_in_unit::Union{Missing,Float64}
        sample_type::Union{Missing,AbstractString}
        sample_rate::Union{Missing,Float64}
        # errors, use `nothing` to indicate no error
        error::Union{Nothing,String}
    end

A Legolas-generated record type describing a single EDF signal-to-Onda channel
conversion.  The columns are the union of
- fields from `EDF.SignalHeader` (all mandatory)
- the `seconds_per_record` field from `EDF.FileHeader` (mandatory)
- fields from `Onda.SignalV{{ VERSION }}` (optional, may be `missing` to indicate failed
  conversion), except for `file_path`
- `error`, which is `nothing` for a conversion that is or is expected to be
  successful, and a `String` describing the source of the error (with backtrace)
  in the case of a caught error.
"""

function _plan_doc(v)
    uniques = if v == 1
        ["kind::Union{Missing,AbstractString}"]
    elseif v == 2 || v == 3
        ["sensor_type::Union{Missing,AbstractString}",
         "sensor_label::Union{Missing,AbstractString}"]
    else
        throw(ArgumentError("Invalid version"))
    end
    samples_per_record_type = v in (1,2) ? "Int16" : "Int32"
    unique_lines = join(map(s -> "        $s", uniques), "\n")
    s = replace(PLAN_DOC_TEMPLATE, "{{ VERSION }}" => v)
    s = replace(s, "{{ SAMPLES_PER_RECORD_TYPE }}" => samples_per_record_type)
    return replace(s, "{{ SAMPLES_INFO_UNIQUE_FIELDS }}" => unique_lines)
end

@doc _plan_doc(1) PlanV1
@doc _plan_doc(2) PlanV2
@doc _plan_doc(3) PlanV3

@schema "ondaedf.file-plan" FilePlan

@version FilePlanV1 > PlanV1 begin
    edf_signal_index::Int
    onda_signal_index::Int
end

@version FilePlanV2 > PlanV2 begin
    edf_signal_index::Int
    onda_signal_index::Int
end

@version FilePlanV3 > PlanV3 begin
    edf_signal_index::Int
    onda_signal_index::Int
end

const FILE_PLAN_DOC_TEMPLATE = """
    @version FilePlanV{{ VERSION }} > PlanV{{ VERSION }} begin
        edf_signal_index::Int
        onda_signal_index::Int
    end

A Legolas-generated record type representing one EDF signal-to-Onda channel conversion,
which includes the columns of a [`PlanV{{ VERSION }}`](@ref) and additional file-level context:
- `edf_signal_index` gives the index of the `signals` in the source `EDF.File`
  corresponding to this row
- `onda_signal_index` gives the index of the output `Onda.Samples`.

Note that while the EDF index does correspond to the actual index in
`edf.signals`, some Onda indices may be skipped in the output, so
`onda_signal_index` is only to indicate order and grouping.
"""

function _file_plan_doc(v)
    s = replace(FILE_PLAN_DOC_TEMPLATE, "{{ VERSION }}" => v)
    return s
end

@doc _file_plan_doc(1) FilePlanV1
@doc _file_plan_doc(2) FilePlanV2
@doc _file_plan_doc(3) FilePlanV3

const OndaEDFSchemaVersions = Union{PlanV1SchemaVersion,FilePlanV1SchemaVersion,
                                    PlanV2SchemaVersion,FilePlanV2SchemaVersion,
                                    PlanV3SchemaVersion,FilePlanV3SchemaVersion}
Legolas.accepted_field_type(::OndaEDFSchemaVersions, ::Type{String}) = AbstractString
# we need this because Arrow write can introduce a Missing for the error column
# (I think because of how missing/nothing sentinels are handled?)
Legolas.accepted_field_type(::OndaEDFSchemaVersions, ::Type{Union{Nothing,String}}) = Union{Nothing,Missing,AbstractString}

@schema "edf.annotation" EDFAnnotation

"""
    @version EDFAnnotationV1 > AnnotationV1 begin
        value::String
    end

A Legolas-generated record type that represents a single annotation imported
from an EDF Annotation signal.  The `value` field contains the annotation value
as a string.
"""
@version EDFAnnotationV1 > AnnotationV1 begin
    value::String
end

end # module
