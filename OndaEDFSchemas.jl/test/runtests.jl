module OndaEDFSchemasTests

using Arrow
using Legolas
using OndaEDFSchemas
using StableRNGs
using Tables
using Test

function mock_plan(n; v, rng=GLOBAL_RNG)
    tbl = [mock_plan(; v, rng) for _ in 1:n]
    return tbl
end

function mock_plan(; v, rng=GLOBAL_RNG)
    ingested = rand(rng, Bool)
    specific_kwargs = if v == 1
        (; kind=ingested ? "eeg" : missing)
    elseif v == 2
        (; sensor_type=ingested ? "eeg" : missing,
         sensor_label=ingested ? "eeg" : missing)
    else
        error("Invalid version")
    end
    errored = !ingested && rand(rng, Bool)
    PlanVersion = v == 1 ? PlanV1 : PlanV2
    return PlanVersion(; label="EEG CZ-M1",
                       transducer_type="Ag-Cl electrode",
                       physical_dimension="uV",
                       physical_minimum=0.0,
                       physical_maximum=2.0,
                       digital_minimum=-1f4,
                       digital_maximum=1f4,
                       prefilter="HP 0.1Hz; LP 80Hz; N 60Hz",
                       samples_per_record=128,
                       seconds_per_record=1.0,
                       channel=ingested ? "cz-m1" : missing,
                       sample_unit=ingested ? "microvolt" : missing,
                       sample_resolution_in_unit=ingested ? 1f-4 : missing,
                       sample_offset_in_unit=ingested ? 1.0 : missing,
                       sample_type=ingested ? "float32" : missing,
                       sample_rate=ingested ? 1/128 : missing,
                       error=errored ? "Error blah blah" : nothing,
                       specific_kwargs...)
end

function mock_file_plan(n; v, rng=GLOBAL_RNG)
    tbl = [mock_file_plan(; v, rng) for _ in 1:n]
    return tbl
end

function mock_file_plan(; v, rng=GLOBAL_RNG)
    plan = mock_plan(; v, rng)
    PlanVersion = v == 1 ? FilePlanV1 : FilePlanV2
    return PlanVersion(Tables.rowmerge(plan;
                                       edf_signal_index=rand(rng, Int),
                                       onda_signal_index=rand(rng, Int)))
end

@testset "Schema version $v" for v in (1, 2)
    @testset "ondaedf.plan@$v" begin
        rng = StableRNG(10)
        plans = mock_plan(30; v, rng)
        schema = Tables.schema(plans)
        @test nothing === Legolas.validate(schema, Legolas.SchemaVersion("ondaedf.plan", v))
        tbl = Arrow.Table(Arrow.tobuffer(plans; maxdepth=9))
        @test isequal(Tables.columntable(tbl), Tables.columntable(plans))
    end

    @testset "ondaedf.file-plan@$v" begin
        rng = StableRNG(11)
        file_plans = mock_file_plan(50; v, rng)
        schema = Tables.schema(file_plans)
        @test nothing === Legolas.validate(schema, Legolas.SchemaVersion("ondaedf.file-plan", v))
        tbl = Arrow.Table(Arrow.tobuffer(file_plans; maxdepth=9))
        @test isequal(Tables.columntable(tbl), Tables.columntable(file_plans))
    end
end

end
