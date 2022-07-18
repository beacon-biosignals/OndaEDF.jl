module OndaEDFSchemasTests

using Arrow
using Legolas
using OndaEDFSchemas
using StableRNGs
using Tables
using Test

function mock_plan(n; rng=GLOBAL_RNG)
    tbl = [mock_plan(; rng) for _ in 1:n]
    return tbl
end

function mock_plan(; rng=GLOBAL_RNG)
    ingested = rand(rng, Bool)
    errored = !ingested && rand(rng, Bool)
    return Plan(; label="EEG CZ-M1",
                transducer_type="Ag-Cl electrode",
                physical_dimension="uV",
                physical_minimum=0.0,
                physical_maximum=2.0,
                digital_minimum=-1f4,
                digital_maximum=1f4,
                prefilter="HP 0.1Hz; LP 80Hz; N 60Hz",
                samples_per_record=128,
                seconds_per_record=1.0,
                kind=ingested ? "eeg" : missing,
                channel=ingested ? "cz-m1" : missing,
                sample_unit=ingested ? "microvolt" : missing,
                sample_resolution_in_unit=ingested ? 1f-4 : missing,
                sample_offset_in_unit=ingested ? 1.0 : missing,
                sample_type=ingested ? "float32" : missing,
                sample_rate=ingested ? 1/128 : missing,
                # errors, use `nothing` to indicate no error
                error=errored ? "Error blah blah" : nothing)
end

function mock_file_plan(n; rng=GLOBAL_RNG)
    tbl = [mock_file_plan(; rng) for _ in 1:n]
    return tbl
end

function mock_file_plan(; rng=GLOBAL_RNG)
    plan = mock_plan(; rng)
    return FilePlan(Tables.rowmerge(plan;
                                    edf_signal_index=rand(rng, Int),
                                    onda_signal_index=rand(rng, Int)))
end

@testset "ondaedf.plan@1" begin
    rng = StableRNG(10)
    plans = mock_plan(30; rng)
    @test nothing === Legolas.validate(plans, Legolas.Schema("ondaedf.plan@1"))
    tbl = Arrow.Table(Arrow.tobuffer(plans))
    @test isequal(Tables.columntable(tbl), Tables.columntable(plans))
end

@testset "ondaedf.file-plan@1" begin
    rng = StableRNG(11)
    plans = mock_file_plan(50; rng)
    @test nothing === Legolas.validate(plans, Legolas.Schema("ondaedf.file-plan@1"))
    tbl = Arrow.Table(Arrow.tobuffer(plans))
    @test isequal(Tables.columntable(tbl), Tables.columntable(plans))
end

end
