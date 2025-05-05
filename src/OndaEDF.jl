module OndaEDF

using Base.Iterators
using Dates
using EDF
using Legolas
using Onda
using OndaEDFSchemas
using PrettyTables
using StatsBase
using TimeSpans
using Tables
using UUIDs

using ArgCheck: @argcheck
using DataStructures: DefaultDict
using Legolas: lift
using OrderedCollections: OrderedDict
using Tables: rowmerge

export edf_to_onda_samples, edf_to_onda_annotations, plan_edf_to_onda_samples, plan_edf_to_onda_samples_groups, store_edf_as_onda
export ConvertedSamples, get_plan, get_samples
export onda_to_edf

const REQUIRED_SIGNAL_GROUPING_COLUMNS = (:sensor_type, :sample_unit, :sample_rate)

include("standards.jl")
include("import_edf.jl")
include("export_edf.jl")

end # module
