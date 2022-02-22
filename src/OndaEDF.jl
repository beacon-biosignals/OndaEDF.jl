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

using Compat: @compat
using Legolas: @row, lift
using Onda: LPCM_SAMPLE_TYPE_UNION, onda_sample_type_from_julia_type, convert_number_to_lpcm_sample_type
using Tables: rowmerge

# can be dropped if we drop Onda<0.14
sample_type(x) = isdefined(Onda, :sample_type) ? Onda.sample_type(x) : x.sample_type

include("standards.jl")

const PlanRow = @row("ondaedf-plan@1",
                     # EDF.SignalHeader fields
                     label::String = convert(String, label),
                     transducer_type::String = convert(String, transducer_type),
                     physical_dimension::String = convert(String, physical_dimension),
                     physical_minimum::Float32 = convert(Float32, physical_minimum),
                     physical_maximum::Float32 = convert(Float32, physical_maximum),
                     digital_minimum::Float32 = convert(Float32, digital_minimum),
                     digital_maximum::Float32 = convert(Float32, digital_maximum),
                     prefilter::AbstractString = convert(String, prefilter),
                     samples_per_record::Int16 = convert(Int16, samples_per_record),
                     # EDF.FileHeader field,
                     seconds_per_record::Float64 = convert(Float64, seconds_per_record),
                     # Onda.SamplesInfo fields (channels -> channel), may be missing
                     kind::Union{Missing, AbstractString} = lift(String, kind),
                     channel::Union{Missing, AbstractString} = lift(String, channel),
                     sample_unit::Union{Missing, AbstractString} = lift(String, sample_unit),
                     sample_resolution_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_resolution_in_unit),
                     sample_offset_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_offset_in_unit),
                     sample_type::Union{Missing, AbstractString} = lift(Onda.onda_sample_type_from_julia_type, sample_type),
                     sample_rate::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = lift(convert_number_to_lpcm_sample_type, sample_rate),
                     # errors, use `nothing` to indicate no error
                     error::Union{Nothing, Exception} = coalesce(error, nothing)
                     )


include("import_edf.jl")
export edf_to_onda_samples, edf_to_onda_annotations, store_edf_as_onda

include("export_edf.jl")
export onda_to_edf

end # module
