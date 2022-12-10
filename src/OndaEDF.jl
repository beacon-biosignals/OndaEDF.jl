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

using Legolas: lift
using Tables: rowmerge

export write_plan
export edf_to_onda_samples, edf_to_onda_annotations, plan_edf_to_onda_samples, plan_edf_to_onda_samples_groups, store_edf_as_onda
export onda_to_edf

include("standards.jl")

"""
    write_plan(io_or_path, plan_table; validate=true, kwargs...)

Write a plan table to `io_or_path` using `Legolas.write`, using the
`ondaedf.file-plan@1` schema.
"""
function write_plan(io_or_path, plan_table; kwargs...)
    return Legolas.write(io_or_path, plan_table,
                         Legolas.SchemaVersion("ondaedf.file-plan", 1);
                         kwargs...)
end

include("import_edf.jl")

include("export_edf.jl")

end # module
