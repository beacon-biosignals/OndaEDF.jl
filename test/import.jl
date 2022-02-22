using OndaEDF: validate_arrow_prefix, plan
using Tables: rowmerge

@testset "Import EDF" begin

    @testset "edf_to_onda_samples" begin
        n_records = 100
        for T in (Int16, EDF.Int24)
            edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records, T)

            returned_samples, plan = OndaEDF.edf_to_onda_samples(edf)
            @test length(returned_samples) == 13

            samples_info = Dict(s.info.kind => s.info for s in returned_samples)
            @test samples_info["tidal_volume"].channels == ["tidal_volume"]
            @test samples_info["tidal_volume"].sample_unit == "milliliter"
            @test samples_info["respiratory_effort"].channels == ["chest", "abdomen"]
            @test samples_info["respiratory_effort"].sample_unit == "microvolt"
            @test samples_info["snore"].channels == ["snore"]
            @test samples_info["snore"].sample_unit == "microvolt"
            @test samples_info["ecg"].channels == ["avr", "avl"]
            @test samples_info["ecg"].sample_unit == "microvolt"
            @test samples_info["positive_airway_pressure"].channels == ["ipap", "epap"]
            @test samples_info["positive_airway_pressure"].sample_unit == "centimeter_of_water"
            @test samples_info["heart_rate"].channels == ["heart_rate"]
            @test samples_info["heart_rate"].sample_unit == "beat_per_minute"
            @test samples_info["emg"].channels == ["left_anterior_tibialis", "right_anterior_tibialis", "intercostal"]
            @test samples_info["emg"].sample_unit == "microvolt"
            @test samples_info["eog"].channels == ["left", "right"]
            @test samples_info["eog"].sample_unit == "microvolt"
            @test samples_info["eeg"].channels == ["f3-m2", "f4-m1", "c3-m2",
                                                   "o1-m2", "c4-m1", "o2-a1", "fpz"]
            @test samples_info["eeg"].sample_unit == "microvolt"
            @test samples_info["pap_device_cflow"].channels == ["pap_device_cflow"]
            @test samples_info["pap_device_cflow"].sample_unit == "liter_per_minute"
            @test samples_info["pap_device_leak"].channels == ["pap_device_leak"]
            @test samples_info["pap_device_leak"].sample_unit == "liter_per_minute"
            @test samples_info["sao2"].channels == ["sao2"]
            @test samples_info["sao2"].sample_unit == "percent"
            @test samples_info["ptaf"].channels == ["ptaf"]
            @test samples_info["ptaf"].sample_unit == "volt"

            @test all(Onda.duration(s) == Nanosecond(Second(200)) for s in returned_samples)
        end
    end

    @testset "store_edf_as_onda" begin
        n_records = 100
        edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)

        root = mktempdir()
        uuid = uuid4()
        nt = OndaEDF.store_edf_as_onda(edf, root, uuid)
        signals = Dict(s.kind => s for s in nt.signals)

        @test nt.signals_path == joinpath(root, "edf.onda.signals.arrow")
        @test nt.annotations_path == joinpath(root, "edf.onda.annotations.arrow")
        @test isfile(nt.signals_path)
        @test isfile(nt.annotations_path)

        @test nt.recording_uuid == uuid
        @test length(nt.signals) == 13
        @testset "samples info" begin
            @test signals["tidal_volume"].channels == ["tidal_volume"]
            @test signals["tidal_volume"].sample_unit == "milliliter"
            @test signals["respiratory_effort"].channels == ["chest", "abdomen"]
            @test signals["respiratory_effort"].sample_unit == "microvolt"
            @test signals["snore"].channels == ["snore"]
            @test signals["snore"].sample_unit == "microvolt"
            @test signals["ecg"].channels == ["avr", "avl"]
            @test signals["ecg"].sample_unit == "microvolt"
            @test signals["positive_airway_pressure"].channels == ["ipap", "epap"]
            @test signals["positive_airway_pressure"].sample_unit == "centimeter_of_water"
            @test signals["heart_rate"].channels == ["heart_rate"]
            @test signals["heart_rate"].sample_unit == "beat_per_minute"
            @test signals["emg"].channels == ["left_anterior_tibialis", "right_anterior_tibialis", "intercostal"]
            @test signals["emg"].sample_unit == "microvolt"
            @test signals["eog"].channels == ["left", "right"]
            @test signals["eog"].sample_unit == "microvolt"
            @test signals["eeg"].channels == ["f3-m2", "f4-m1", "c3-m2",
                                              "o1-m2", "c4-m1", "o2-a1", "fpz"]
            @test signals["eeg"].sample_unit == "microvolt"
            @test signals["pap_device_cflow"].channels == ["pap_device_cflow"]
            @test signals["pap_device_cflow"].sample_unit == "liter_per_minute"
            @test signals["pap_device_leak"].channels == ["pap_device_leak"]
            @test signals["pap_device_leak"].sample_unit == "liter_per_minute"
            @test signals["sao2"].channels == ["sao2"]
            @test signals["sao2"].sample_unit == "percent"
            @test signals["ptaf"].channels == ["ptaf"]
            @test signals["ptaf"].sample_unit == "volt"
        end

        for signal in values(signals)
            @test signal.span.start == Nanosecond(0)
            @test signal.span.stop == Nanosecond(Second(200))
            @test signal.file_format == "lpcm.zst"
        end

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
                @test_logs (:warn, r"Extracting prefix") begin
                    nt = OndaEDF.store_edf_as_onda(edf, root, uuid; signals_prefix="edff.onda.signals.arrow", annotations_prefix="edf")
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

    @testset "error handling" begin
        edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, 100, Int16)

        one_signal = first(edf.signals)
        @test_throws ArgumentError plan(one_signal)
        @test_throws ArgumentError plan(one_signal, missing)
        one_plan = plan(one_signal, edf.header.seconds_per_record)
        @test one_plan.label == one_signal.header.label

        preproc_err = (l, t) -> throw(ErrorException("testing"))
        err_plan = @test_logs (:error,) plan(one_signal, 1.0; preprocess_labels=preproc_err)
        @test err_plan.error isa ErrorException

        # malformed labels/units
        @test_logs (:error,) plan(one_signal, 1.0; labels=[["signal"] => nothing])
        @test_logs (:error,) plan(one_signal, 1.0; units=["millivolt" => nothing])

        # unit not found does not error but does create a missing
        unitless_plan = plan(one_signal, 1.0; units=["millivolt" => ["mV"]])
        @test unitless_plan.error === nothing
        @test ismissing(unitless_plan.sample_unit)

        
        
        # error on execution
        plans = plan(edf)
        # intentionally combine signals of different kinds
        different = findfirst(row -> !isequal(row.kind, first(plans).kind), plans)
        bad_plans = rowmerge.(plans[[1, different]]; onda_signal_idx=1)
        bad_samples, bad_plans_exec = @test_logs (:error,) OndaEDF.execute_plan(bad_plans, edf)
        @test all(row.error isa ArgumentError for row in bad_plans_exec)
        @test all(ismissing, bad_samples)
    end
    
    

end
