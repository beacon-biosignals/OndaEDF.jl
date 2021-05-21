using OndaEDF: validate_arrow_prefix

function test_preprocessor(l)
    l = replace(l, ':' => '-')
    l = replace(l, "\xf6"[1] => 'o') # remove umlaut (German)
    l = replace(l, '\u00F3' => 'o') # remove accute accent (Spanish)
    l = replace(l, '\u00D3' => 'O') # remove accute accent (Spanish)
    # "EOG - L" and "EOG - R" should not be parsed as channel \minus channel
    m = match(r"^\s*EOG[\s\-]+(?<lr>[LR])\s*"i, l)
    if !isnothing(m)
        l = "EOG$(m[:lr])"
    end
    # "L - EOG" and "R- EOG" should not be parsed as channel \minus channel
    m = match(r"^\s*(?<lr>[LR])[\s\-]+EOG\s*"i, l)
    if !isnothing(m)
        l = "EOG$(m[:lr])"
    end
    # "C2M1" => "C2-M1" etc
    m = match(r"\s*(?<channel>[fco][1234])\s*(?<ref>[am][12])\s*"i, l)
    isnothing(m) && return l
    return "$(m[:channel])-$(m[:ref])"
end

custom_extractors = [edf -> extract_channels_by_label(edf, signal_names, channel_names; preprocess_labels=test_preprocessor)
                     for (signal_names, channel_names) in OndaEDF.STANDARD_LABELS]

@testset "Import EDF" begin

    @testset "edf_to_samples_info" begin
        results = map(test_edf_to_samples_info) do r
            edf = mock_edf(r)
            original_edf_headers = [s.header for s in edf.signals]
            try
                samples, errors = OndaEDF.edf_to_onda_samples(edf; custom_extractors=custom_extractors)
                return ((onda_edf_headers=[s.info for s in samples],
                         original_edf_headers=original_edf_headers,
                         error=errors),
                        r.onda_edf_headers)
            catch e
                return ((onda_edf_headers=[],
                         original_edf_headers=original_edf_headers,
                         error=[e]),
                        r.onda_edf_headers)
            end
        end
        # print result of mapping `edf_to_onda_samples` over `test_edf_to_samples_info.out`
        # this makes it easy to see effects of any changes made to OndaEDF by looking at
        # `diff test_edf_to_samples_info.out test_edf_to_samples_info.tested.out`
        print_results("test_edf_to_samples_info_tested", map(first, results))
        print_results("no_eeg_tested", filter(nt -> !any(h -> h.kind == "eeg", nt.onda_edf_headers), map(first, results)))
        print_results("no_eog_tested", filter(nt -> !any(h -> h.kind == "eog", nt.onda_edf_headers), map(first, results)))
        print_results("no_emg_tested", filter(nt -> !any(h -> h.kind == "emg", nt.onda_edf_headers), map(first, results)))
        print_results("no_ekg_tested", filter(nt -> !any(h -> h.kind ∈ Set(("ecg", "ekg")), nt.onda_edf_headers), map(first, results)))
        for (i, (r, expected_samples_info)) in enumerate(results)
            expected = [(s.kind, c, s.sample_unit) for s in expected_samples_info for c in s.channels]
            sample_infos = [(s.kind, c, s.sample_unit) for s in r.onda_edf_headers for c in s.channels]
            @test (i, setdiff(expected, sample_infos)) == (i, [])
        end
    end

    n_records = 100
    edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)

    @testset "edf_to_onda_samples" begin
        returned_samples, errors = OndaEDF.edf_to_onda_samples(edf)
        @test length(returned_samples) == 13

        samples_info = Dict(s.info.kind => s.info for s in returned_samples)
        @test samples_info["tidal_volume"].channels == ["tidal_volume"]
        @test samples_info["tidal_volume"].sample_unit == "milliliter"
        @test samples_info["respiratory_effort"].channels == ["chest", "abdomen"]
        @test samples_info["respiratory_effort"].sample_unit == "microvolt"
        @test samples_info["snore"].channels == ["snore"]
        @test samples_info["snore"].sample_unit == "microvolt"
        @test samples_info["ecg"].channels == ["avl", "avr"]
        @test samples_info["ecg"].sample_unit == "microvolt"
        @test samples_info["positive_airway_pressure"].channels == ["ipap", "epap"]
        @test samples_info["positive_airway_pressure"].sample_unit == "centimeter_of_water"
        @test samples_info["heart_rate"].channels == ["heart_rate"]
        @test samples_info["heart_rate"].sample_unit == "beat_per_minute"
        @test samples_info["emg"].channels == ["intercostal", "left_anterior_tibialis", "right_anterior_tibialis"]
        @test samples_info["emg"].sample_unit == "microvolt"
        @test samples_info["eog"].channels == ["left", "right"]
        @test samples_info["eog"].sample_unit == "microvolt"
        @test samples_info["eeg"].channels == ["fpz", "f3-m2", "f4-m1", "c3-m2",
                                               "c4-m1", "o1-m2", "o2-a1"]
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


    @testset "store_edf_as_onda" begin
        root = mktempdir()
        uuid = uuid4()
        returned_uuid, (returned_signals, annotations) = OndaEDF.store_edf_as_onda(root, edf, uuid)
        signals = Dict(s.kind => s for s in returned_signals)

        @test isfile(joinpath(root, "edf.onda.signals.arrow"))
        @test isfile(joinpath(root, "edf.onda.annotations.arrow"))

        @test returned_uuid == uuid
        @test length(returned_signals) == 13
        @testset "samples info" begin
            @test signals["tidal_volume"].channels == ["tidal_volume"]
            @test signals["tidal_volume"].sample_unit == "milliliter"
            @test signals["respiratory_effort"].channels == ["chest", "abdomen"]
            @test signals["respiratory_effort"].sample_unit == "microvolt"
            @test signals["snore"].channels == ["snore"]
            @test signals["snore"].sample_unit == "microvolt"
            @test signals["ecg"].channels == ["avl", "avr"]
            @test signals["ecg"].sample_unit == "microvolt"
            @test signals["positive_airway_pressure"].channels == ["ipap", "epap"]
            @test signals["positive_airway_pressure"].sample_unit == "centimeter_of_water"
            @test signals["heart_rate"].channels == ["heart_rate"]
            @test signals["heart_rate"].sample_unit == "beat_per_minute"
            @test signals["emg"].channels == ["intercostal", "left_anterior_tibialis", "right_anterior_tibialis"]
            @test signals["emg"].sample_unit == "microvolt"
            @test signals["eog"].channels == ["left", "right"]
            @test signals["eog"].sample_unit == "microvolt"
            @test signals["eeg"].channels == ["fpz", "f3-m2", "f4-m1", "c3-m2",
                                              "c4-m1", "o1-m2", "o2-a1"]
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

        for (signal_name, edf_indices) in edf_channel_indices
            onda_samples = load(signals[string(signal_name)]).data
            edf_samples = mapreduce(transpose ∘ EDF.decode, vcat, edf.signals[edf_indices])
            @test isapprox(onda_samples, edf_samples; rtol=0.02)
        end

        @testset "Annotations import" begin
            @test length(annotations) == n_records * 4
            # check whether all four types of annotations are preserved on import:
            for i in 1:n_records
                start = Nanosecond(Second(i))
                stop = start + Nanosecond(Second(i + 1))
                # two annotations with same 1s span and different values:
                @test any(a -> a.value == "$i a" && a.span.start == start && a.span.stop == stop, annotations)
                @test any(a -> a.value == "$i b" && a.span.start == start && a.span.stop == stop, annotations)
                # two annotations with instantaneous (1ns) span and different values
                @test any(a -> a.value == "$i c" && a.span.start == start && a.span.stop == start + Nanosecond(1), annotations)
                @test any(a -> a.value == "$i d" && a.span.start == start && a.span.stop == start + Nanosecond(1), annotations)
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
                OndaEDF.store_edf_as_onda(root, edf, uuid; signals_prefix="edfff")
                @test isfile(joinpath(root, "edfff.onda.signals.arrow"))
                @test isfile(joinpath(root, "edfff.onda.annotations.arrow"))
            end

            mktempdir() do root
                OndaEDF.store_edf_as_onda(root, edf, uuid; annotations_prefix="edff")
                @test isfile(joinpath(root, "edf.onda.signals.arrow"))
                @test isfile(joinpath(root, "edff.onda.annotations.arrow"))
            end

            mktempdir() do root
                OndaEDF.store_edf_as_onda(root, edf, uuid; annotations_prefix="edff")
                @test isfile(joinpath(root, "edf.onda.signals.arrow"))
                @test isfile(joinpath(root, "edff.onda.annotations.arrow"))
            end

            mktempdir() do root
                OndaEDF.store_edf_as_onda(root, edf, uuid; signals_prefix="edfff", annotations_prefix="edff")
                @test isfile(joinpath(root, "edfff.onda.signals.arrow"))
                @test isfile(joinpath(root, "edff.onda.annotations.arrow"))
            end

            mktempdir() do root
                @test_logs (:warn, r"Extracting prefix") OndaEDF.store_edf_as_onda(root, edf, uuid; signals_prefix="edff.onda.signals.arrow", annotations_prefix="edf")
                @test isfile(joinpath(root, "edff.onda.signals.arrow"))
                @test isfile(joinpath(root, "edf.onda.annotations.arrow"))
            end

            mktempdir() do root
                @test_throws ArgumentError OndaEDF.store_edf_as_onda(root, edf, uuid; signals_prefix="stuff/edf", annotations_prefix="edf")
            end
            
        end
    end

end
