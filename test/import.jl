@testset "Import EDF" begin

    @testset "edf_to_onda_samples" begin
        n_records = 100
        for T in (Int16, EDF.Int24)
            edf, edf_channel_indices = make_test_data(StableRNG(42), 256, 512, n_records, T)

            returned_samples, plan = OndaEDF.edf_to_onda_samples(edf)
            @test length(returned_samples) == 13

            returned_samples = values(returned_samples)
            validate_extracted_signals(s.info for s in returned_samples)
            @test all(Onda.duration(s) == Nanosecond(Second(200)) for s in returned_samples)
        end
    end

    @testset "edf_to_onda_samples with manual override" begin
        n_records = 100
        edf, edf_channel_indices = make_test_data(StableRNG(42), 256, 512, n_records, Int16)
        @test_throws(ArgumentError(":seconds_per_record not found in header, or missing"),
                     plan_edf_to_onda_samples.(filter(x -> isa(x, EDF.Signal), edf.signals)))

        signal_plans = plan_edf_to_onda_samples.(filter(x -> isa(x, EDF.Signal), edf.signals),
                                                 edf.header.seconds_per_record)

        @testset "signal-wise plan" begin
            grouped_plans = plan_edf_to_onda_samples_groups(signal_plans)
            returned_samples, plan = OndaEDF.edf_to_onda_samples(edf, grouped_plans)

            validate_extracted_signals(s.info for s in values(returned_samples))
        end

        @testset "custom grouping" begin
            # one channel per signal, group by label
            grouped_plans = plan_edf_to_onda_samples_groups(signal_plans,
                                                            extra_onda_signal_groupby=(:label,))
            returned_samples, plan = edf_to_onda_samples(edf, grouped_plans)
            @test all(==(1), channel_count.(values(returned_samples)))
        end

        @testset "plan sensor_labels are respected" begin
            grouped_plans = plan_edf_to_onda_samples_groups(signal_plans)
            grouped_plans = let
                ecg_count = 1
                map(grouped_plans) do plan
                    sensor_label = "edf_" * plan.sensor_label
                    if isequal(plan.sensor_type, "ecg")
                        sensor_label *= string('_', ecg_count)
                        ecg_count += 1
                    end
                    return Tables.rowmerge(plan; sensor_label)
                end
            end

            returned_samples, plan = OndaEDF.edf_to_onda_samples(edf, grouped_plans)

            @test haskey(returned_samples, "edf_ecg_1")
            @test haskey(returned_samples, "edf_ecg_2")
            @test all(startswith("edf_"), keys(returned_samples))
        end

        @testset "preserve existing row index" begin
            # we test this by first setting the numbers, then reversing the row
            # orders before grouping.
            plans_numbered = [rowmerge(plan; edf_signal_index)
                              for (edf_signal_index, plan)
                              in enumerate(signal_plans)]
            plans_rev = reverse!(plans_numbered)
            @test last(plans_rev).edf_signal_index == 1

            grouped_plans_rev = plan_edf_to_onda_samples_groups(plans_rev)
            returned_samples, plan = edf_to_onda_samples(edf, grouped_plans_rev)
            # we need to re-reverse the order of channels to get to what's
            # expected in teh tests
            infos = [rowmerge(s.info; channels=reverse(s.info.channels))
                     for s in values(returned_samples)]
            validate_extracted_signals(infos)

            # test also that this will error about mismatch between plan label
            # and signal label without pre-numbering
            plans_rev_bad = [rowmerge(plan; edf_signal_index=missing)
                             for plan in plans_rev]
            grouped_plans_rev_bad = plan_edf_to_onda_samples_groups(plans_rev_bad)
            @test_throws(ArgumentError("Plan's label EcG EKGL does not match EDF label EEG C3-M2!"),
                         edf_to_onda_samples(edf, grouped_plans_rev_bad))
        end
    end

    @testset "store_edf_as_onda" begin
        n_records = 100
        edf, edf_channel_indices = make_test_data(StableRNG(42), 256, 512, n_records)

        root = mktempdir()
        uuid = uuid4()
        nt = OndaEDF.store_edf_as_onda(edf, root, uuid)

        @test nt.signals_path == joinpath(root, "edf.onda.signals.arrow")
        @test nt.annotations_path == joinpath(root, "edf.onda.annotations.arrow")
        @test isfile(nt.signals_path)
        @test isfile(nt.annotations_path)

        @test nt.recording_uuid == uuid
        @test length(nt.signals) == 13
        @testset "samples info" begin
            validate_extracted_signals(nt.signals)
        end

        for signal in nt.signals
            @test signal.span.start == Nanosecond(0)
            @test signal.span.stop == Nanosecond(Second(200))
            @test signal.file_format == "lpcm.zst"
        end

        signals = Dict(s.sensor_type => s for s in nt.signals)

        @testset "Signal roundtrip" begin
            for (signal_name, edf_indices) in edf_channel_indices
                @testset "$signal_name" begin
                    onda_samples = load(signals[string(signal_name)]).data
                    edf_samples = mapreduce(transpose ∘ EDF.decode, vcat, edf.signals[sort(edf_indices)])
                    @test isapprox(onda_samples, edf_samples; rtol=0.02)
                end
            end
        end

        @testset "Annotations import" begin
            @test length(nt.annotations) == n_records * 4
            # check whether all four types of annotations are preserved on import:
            for i in 1:n_records
                start = Nanosecond(Second(i))
                stop = start + Nanosecond(Second(i + 1))
                # two annotations with same 1s span and different values:
                @test any(a -> a.value == "$i a" && a.span.start == start && a.span.stop == stop, nt.annotations)
                @test any(a -> a.value == "$i b" && a.span.start == start && a.span.stop == stop, nt.annotations)
                # two annotations with instantaneous (1ns) span and different values
                @test any(a -> a.value == "$i c" && a.span.start == start && a.span.stop == start + Nanosecond(1), nt.annotations)
                @test any(a -> a.value == "$i d" && a.span.start == start && a.span.stop == start + Nanosecond(1), nt.annotations)
            end
        end

        @testset "Table prefixes" begin
            prefix = @test_nowarn validate_arrow_prefix("edf")
            @test prefix == "edf"
            prefix = @test_nowarn validate_arrow_prefix("edf.something")
            @test prefix == "edf.something"
            @test_throws ArgumentError validate_arrow_prefix("/edf.something")
            @test_throws ArgumentError validate_arrow_prefix("subdir/something")
            prefix = @test_logs (:warn, r"Extracting prefix \"edf\"") validate_arrow_prefix("edf.onda.signals.arrow")
            @test prefix == "edf"
            prefix = @test_logs (:warn, r"Extracting prefix \"edf\"") validate_arrow_prefix("edf.onda.annotations.arrow")
            @test prefix == "edf"

            mktempdir() do root
                nt = OndaEDF.store_edf_as_onda(edf, root, uuid; signals_prefix="edfff")
                @test nt.signals_path == joinpath(root, "edfff.onda.signals.arrow")
                @test nt.annotations_path == joinpath(root, "edfff.onda.annotations.arrow")
            end

            mktempdir() do root
                nt = OndaEDF.store_edf_as_onda(edf, root, uuid; annotations_prefix="edff")
                @test nt.signals_path == joinpath(root, "edf.onda.signals.arrow")
                @test nt.annotations_path == joinpath(root, "edff.onda.annotations.arrow")
            end

            mktempdir() do root
                nt = OndaEDF.store_edf_as_onda(edf, root, uuid; annotations_prefix="edff")
                @test nt.signals_path == joinpath(root, "edf.onda.signals.arrow")
                @test nt.annotations_path == joinpath(root, "edff.onda.annotations.arrow")
            end

            mktempdir() do root
                nt = OndaEDF.store_edf_as_onda(edf, root, uuid; signals_prefix="edfff", annotations_prefix="edff")
                @test nt.signals_path == joinpath(root, "edfff.onda.signals.arrow")
                @test nt.annotations_path == joinpath(root, "edff.onda.annotations.arrow")
            end

            mktempdir() do root
                nt = @test_logs (:warn, r"Extracting prefix") begin
                    OndaEDF.store_edf_as_onda(edf, root, uuid; signals_prefix="edff.onda.signals.arrow", annotations_prefix="edf")
                end
                @test nt.signals_path == joinpath(root, "edff.onda.signals.arrow")
                @test nt.annotations_path == joinpath(root, "edf.onda.annotations.arrow")
            end

            mktempdir() do root
                @test_throws ArgumentError OndaEDF.store_edf_as_onda(edf, root, uuid; signals_prefix="stuff/edf", annotations_prefix="edf")
            end
        end

        @testset "AbstractPath support" begin
            mktempdir() do dir
                root = PosixPath(dir)
                nt = OndaEDF.store_edf_as_onda(edf, root, uuid)

                @test nt.signals_path isa AbstractPath
                @test isfile(nt.signals_path)
                @test nt.annotations_path isa AbstractPath
                @test isfile(nt.annotations_path)
                @test isdir(joinpath(dirname(nt.signals_path), "samples"))
                @test all(p -> p isa AbstractPath, (s.file_path for s in nt.signals))
            end
        end
    end

    @testset "duplicate sensor_type" begin
        rng = StableRNG(1234)
        _signal = function(label, transducer, unit, lo, hi)
            return test_edf_signal(rng, label, transducer, unit, lo, hi,
                                   Float32(typemin(Int16)),
                                   Float32(typemax(Int16)),
                                   128, 10, Int16)
        end
        T = Union{EDF.AnnotationsSignal, EDF.Signal{Int16}}
        edf_signals = T[_signal("EMG Chin1", "E", "mV", -100, 100),
                        _signal("EMG Chin2", "E", "mV", -120, 90),
                        _signal("EMG LAT", "E", "uV", 0, 1000)]
        edf_header = EDF.FileHeader("0", "", "", DateTime("2014-10-27T22:24:28"),
                                    true, 10, 1)
        test_edf = EDF.File(IOBuffer(), edf_header, edf_signals)

        plan = plan_edf_to_onda_samples(test_edf)
        sensors = Tables.columntable(unique((; p.sensor_type, p.sensor_label) for p in plan))
        @test length(sensors.sensor_type) == 2
        @test all(==("emg"), sensors.sensor_type)
        @test allunique(sensors.sensor_label)
    end

    @testset "error handling" begin
        edf, edf_channel_indices = make_test_data(StableRNG(42), 256, 512, 100, Int16)

        one_signal = first(edf.signals)
        @test_throws ArgumentError plan_edf_to_onda_samples(one_signal)
        @test_throws ArgumentError plan_edf_to_onda_samples(one_signal, missing)
        one_plan = plan_edf_to_onda_samples(one_signal, edf.header.seconds_per_record)
        @test one_plan.label == one_signal.header.label

        @test_throws ArgumentError plan_edf_to_onda_samples(one_signal, 1.0; preprocess_labels=identity)

        err_plan = @test_logs (:error, ) plan_edf_to_onda_samples(one_signal, 1.0; units=[1, 2, 3])
        @test err_plan.error isa String
        # malformed units arg: elements should be de-structurable
        @test contains(err_plan.error, "BoundsError")

        # malformed labels/units
        @test_logs (:error,) plan_edf_to_onda_samples(one_signal, 1.0; labels=[["signal"] => nothing])
        @test_logs (:error,) plan_edf_to_onda_samples(one_signal, 1.0; units=["millivolt" => nothing])

        # unit not found does not error but does create a missing
        unitless_plan = plan_edf_to_onda_samples(one_signal, 1.0; units=["millivolt" => ["mV"]])
        @test unitless_plan.error === nothing
        @test ismissing(unitless_plan.sample_unit)

        # error on execution
        plans = plan_edf_to_onda_samples(edf)
        # intentionally combine signals of different sensor_types
        different = findfirst(row -> !isequal(row.sensor_type, first(plans).sensor_type), plans)
        bad_plans = rowmerge.(plans[[1, different]]; sensor_label=plans[1].sensor_label)
        bad_samples, bad_plans_exec = @test_logs (:error,) OndaEDF.edf_to_onda_samples(edf, bad_plans)
        @test all(row.error isa String for row in bad_plans_exec)
        @test all(occursin("ArgumentError", row.error) for row in bad_plans_exec)
        @test isempty(bad_samples)
    end

    @testset "units labels and encoding matched independently" begin
        n_records = 100
        edf, edf_channel_indices = make_test_data(StableRNG(42), 256, 512, n_records, Int16)

        signal = edf.signals[1]
        header = signal.header

        plan = plan_edf_to_onda_samples(header, edf.header.seconds_per_record)
        no_label = plan_edf_to_onda_samples(header, edf.header.seconds_per_record;
                                            labels=Dict())
        no_units = plan_edf_to_onda_samples(header, edf.header.seconds_per_record;
                                            units=Dict())
        no_both = plan_edf_to_onda_samples(header, edf.header.seconds_per_record;
                                           units=Dict(), labels=Dict())

        @test ismissing(no_label.channel)
        @test ismissing(no_label.sensor_type)
        @test no_label.sample_unit == plan.sample_unit
        @test no_label.sample_resolution_in_unit == plan.sample_resolution_in_unit
        @test no_label.sample_offset_in_unit == plan.sample_offset_in_unit

        @test no_units.channel == plan.channel
        @test no_units.sensor_type == plan.sensor_type
        @test ismissing(no_units.sample_unit)
        @test no_units.sample_resolution_in_unit == plan.sample_resolution_in_unit
        @test no_units.sample_offset_in_unit == plan.sample_offset_in_unit

        @test ismissing(no_both.channel)
        @test ismissing(no_both.sensor_type)
        @test ismissing(no_both.sample_unit)
        @test no_both.sample_resolution_in_unit == plan.sample_resolution_in_unit
        @test no_both.sample_offset_in_unit == plan.sample_offset_in_unit
    end

    @testset "de/serialization of plans" begin
        edf, _ = make_test_data(StableRNG(42), 256, 512, 100, Int16)
        plan = plan_edf_to_onda_samples(edf)
        @test validate(Tables.schema(plan),
                       SchemaVersion("ondaedf.file-plan", 3)) === nothing

        samples, plan_exec = edf_to_onda_samples(edf, plan)
        @test validate(Tables.schema(plan_exec),
                       SchemaVersion("ondaedf.file-plan", 3)) === nothing

        plan_rt = let io=IOBuffer()
            OndaEDF.write_plan(io, plan)
            seekstart(io)
            Legolas.read(io; validate=true)
        end

        plan_exec_cols = Tables.columns(plan_exec)
        plan_rt_cols = Tables.columns(plan_rt)
        for col in Tables.columnnames(plan_exec_cols)
            @test all(isequal.(Tables.getcolumn(plan_rt_cols, col), Tables.getcolumn(plan_exec_cols, col)))
        end
    end

end
