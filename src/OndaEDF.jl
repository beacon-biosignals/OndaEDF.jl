module OndaEDF

using Base.Iterators
using Compat: @compat
using Dates, UUIDs
using Legolas
using Onda, EDF
using StatsBase
using TimeSpans
using Tables

using Legolas: @row
using Onda: LPCM_SAMPLE_TYPE_UNION, onda_sample_type_from_julia_type, convert_number_to_lpcm_sample_type
using Tables: rowmerge

# can be dropped if we drop Onda<0.14
sample_type(x) = isdefined(Onda, :sample_type) ? Onda.sample_type(x) : x.sample_type

include("standards.jl")

const PlanRow = @row("ondaedf-plan@1",
                     # EDF.SignalHeader fields
                     label::String = convert(String, label)
                     transducer_type::String = convert(String, transducer_type)
                     physical_dimension::String = convert(String, physical_dimension)
                     physical_minimum::Float32 = convert(Float32, physical_minimum)
                     physical_maximum::Float32 = convert(Float32, physical_maximum)
                     digital_minimum::Float32 = convert(Float32, digital_minimum)
                     digital_maximum::Float32 = convert(Float32, digital_maximum)
                     prefilter::AbstractString = convert(String, prefilter)
                     samples_per_record::Int16 = convert(Int16, samples_per_record)
                     # EDF.FileHeader field
                     seconds_per_record::Float64 = convert(Float64, seconds_per_record)
                     # Onda.SamplesInfo fields (channels -> channel)
                     kind::Union{Missing, AbstractString} = missing
                     channel::Union{Missing, AbstractString} = missing
                     sample_unit::Union{Missing, AbstractString} = missing
                     sample_resolution_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = missing
                     sample_offset_in_unit::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = missing
                     sample_type::Union{Missing, AbstractString} = missing
                     sample_rate::Union{Missing, LPCM_SAMPLE_TYPE_UNION} = missing
                     # errors
                     error::Union{Nothing, Exception} = nothing
                     )


include("import_edf.jl")
export edf_to_onda_samples, edf_to_onda_annotations, store_edf_as_onda
export extract_channels_by_label, edf_signals_to_samplesinfo

include("export_edf.jl")
export onda_to_edf

end # module
