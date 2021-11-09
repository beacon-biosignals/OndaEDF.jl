using OndaEDF: validate_arrow_prefix, prettyprint_diagnostic_info, mock_edf

function test_preprocessor(l, t)
    l = replace(l, ':' => '-')
    l = replace(l, "\xf6"[1] => 'o') # remove umlaut (German)
    l = replace(l, '\u00F3' => 'o') # remove accute accent (Spanish)
    l = replace(l, '\u00D3' => 'O') # remove accute accent (Spanish)
    l = OndaEDF._safe_lowercase(l)
    t = OndaEDF._safe_lowercase(t)

    l = replace(l, r"\.$"i => "")

    ####
    # ODDBALLS

    m = match(r"\[chin-(?<lr>[lr])-chin-[ar]\]"i, l)
    l = isnothing(m) ? l : "emg chin$(m[:lr])"
    
    l = endswith(l, "clavicle") ? "ecg avl" : l

    l = l == "ekg8" ? "ekg v8" : l
    l = replace(l, r"^e1 14" => "e1")
    l = replace(l, r"^e2 18" => "e2")
    
    l = endswith(l, "cardiogr") ? "ecg avl" : l

    l = l == "ecg+" ? "ecg" : l
    l = l == "ecg-" ? "ecg" : l

    if t == "ekg_channel"
        l = "ecg"
    end

    if l == "eog" && t == ""
        l = "eog l"  # recording will have 2 left eogs, no way to say which is which
    end

    l = startswith(l, "eog horz") ? "eog l" : l

    # CHIN1I-CHIN[23][]
    l = replace(l, r"^chin1i-chin.*"i => "emg chin1")

    if t == "leg_channel" && l == "25"
        l = "left_anterior_tibialis"
    end

    if t == "leg2_channel" && l == "26"
        l = "right_anterior_tibialis"
    end

    if t == "chin_channel" && l ∈ ["fz-cz", "24", "p3-p4", "fp1-fp2"]
        l = "emg chin1"
    end

    if t == "chin2_channel" && l ∈ ["25", "p4-pz"]
        l = "emg chin2"
    end

    m = match(r"chin(?<lr>[lr])[\(\s]+ment.*"i, l)
    l = isnothing(m) ? l : "emg chin$(m[:lr])"

    l = l == "emg x1-x6" ? "emg chin1" : l
    
    m = match(r"emg\s+(?<lr>[lr])at\s+.*"i, l)
    l = isnothing(m) ? l : "emg $(m[:lr])at"

    m = match(r"[lr]leg[\+\-]"i, l)
    l = isnothing(m) ? l : "ignorame"

    m = match(r"^(?<lr>[lr])t\. eye"i, l)
    l = isnothing(m) ? l : "eog $(m[:lr])"

    l = l == "e1 (l)-m2" ? "eog l" : l
    l = l == "e2 (r)-m2" ? "eog r" : l

    l = l == "chinz-chin1" ? "emg chinl" : l
    l = l == "chinz-chin2" ? "emg chinr" : l

    l = l == "eog x4-a2" ? "eog r" : l
    l = l == "eog x9-a2" ? "eog l" : l

    #m = match(r"^eeg (?<lr>[lr]oc)(?<rest>.*)$"i, l)
    #l = isnothing(m) ? l : "eog $(m[:lr])$(m[:rest])"

    l = l == "e.left" ? "eog loc" : l
    l = l == "e.right" ? "eog roc" : l

    ###############
    # AMBIGUOUS ONES
    # these will only be kept if recording also has leg EMG in separate channels

    # "EMG[123]" => emg_ambiguous [123]
    m = match(r"^\s*emg_?(?<n>[lr123])\s*$"i, l)
    l = isnothing(m) ? l : "emg_ambiguous $(m[:n])"

    # "EMG\s*Aux[123]" => emg_ambiguous [123]
    m = match(r"^\s*emg\s*aux(?<n>[123])\s*$"i, l)
    l = isnothing(m) ? l : "emg_ambiguous $(m[:n])"

    # "EMG_[LR]" => emg_ambiguous [12]
    m = match(r"^\s*emg(?<n>[123])\s*$"i, l)
    l = isnothing(m) ? l : "emg_ambiguous $(m[:n])"

    # EMG[+-]? => EMG Aux[123]
    l = l == "emg+" ? "emg_ambiguous 1" : l 
    l = l == "emg-" ? "emg_ambiguous 2" : l 
    l = l == "emg" ? "emg_ambiguous 3" : l    # postprocess: if only "emg_ambiguous 3" + legs present, replace with "EMG chin1"

    # other ambiguous forms
    l = l == "emg1-emg2" ? "emg_ambiguous 1" : l 
    l = l == "emg2-emg1" ? "emg_ambiguous 2" : l 
    l = l == "emg-a1" ? "emg_ambiguous 1" : l 
    l = l == "emg emg" ? "emg_ambiguous 1" : l

    m = match(r"[\s\[,]*emg(?<i>[123]?)[\s\-]+emg([123]?)[\]\s,]*"i, l)
    l = isnothing(m) ? l : "emg_ambiguous $(m[:i])"

    ####
    ####

    # [sub][clavi]?
    m = match(r"l[^r]*sub"i, l)
    l = (isnothing(m) || occursin("subm", l)) ? l : "ecg avl"
    m = match(r"r[^l]*sub"i, l)
    l = (isnothing(m) || occursin("subm", l)) ? l : "ecg avr"

    # [sub]?[clav]
    m = match(r"l[^r]*clav"i, l)
    l = isnothing(m) ? l : "ecg avl"
    m = match(r"r[^l]*clav"i, l)
    l = isnothing(m) ? l : "ecg avr"

    # recordings with label in the transducer field
    l = l == "spectrum eeg" ? t : l

    # "EOG - L" and "EOG - R" should not be parsed as channel \minus channel
    m = match(r"^\s*EOG[\s\-]+(?<lr>[LR])\s*"i, l)
    if !isnothing(m)
        l = "EOG $(m[:lr])"
    end

    # "L - EOG" and "R- EOG" should not be parsed as channel \minus channel
    m = match(r"^[\[\s,\(]*(?<lr>[LR])[\s\-]+EOG(?<rest>[^\]\),]*)\s*[\]\s,\)]*$"i, l)
    if !isnothing(m)
        l = "EOG $(m[:lr])$(m[:rest])"
    end

    # "C2M1" => "C2-M1" etc
    m = match(r"\s*(?<channel>[fco][1234])\s*(?<ref>[am][12])\s*$"i, l)
    l = isnothing(m) ? l : "$(m[:channel])-$(m[:ref])"

    # "Chin EMG[12]?" => "EMG chin[12]?"
    m = match(r"\s*chin\s+emg(?<n>[12]?)\s*"i, l)
    l = isnothing(m) ? l : "emg chin$(m[:n])"

    # Chin[LR123]?.* => chin[lr123]?
    m = match(r"\s*chin(?<side>[lr123]?)\s*(?<rest>[\-chinlr123]*)\s*$"i, l)
    l = isnothing(m) ? l : "emg chin$(m[:side])$(m[:rest])"

    # "Menton (cen.)" => chin3
    m = match(r"\s*menton.*cen.*"i, l)
    l = isnothing(m) ? l : "chin3"

    # "Lower.Left-Upper" => "EMG chin1"
    l = startswith(l, "lower.left-upp") ? "emg chin1" : l 
    l = startswith(l, "lower.right-upp") ? "emg chin2" : l 
    l = startswith(l, "lower.left-low") ? "emg chin1" : l    # dipole; dubious assignment
    l = startswith(l, "lower.right-low") ? "emg chin2" : l   # dipole; dubious assignment

    # how to denote that sign is inverted???
    # "Upper-Lower.Left" => "EMG chin1"
    l = l == "upper-lower.left" ? "emg chin1" : l 
    l = l == "upper-lower.righ" ? "emg chin2" : l 

    # deutsch
    l = l == "emg li" ? "emg chin1" : l 
    l = l == "emg re" ? "emg chin2" : l 
    l = l == "emg mitte" ? "emg chin3" : l 
    l = l == "emg1 kinn" ? "emg chin1" : l 
    l = l == "emg2 kinn" ? "emg chin2" : l 

    # EMG-subm[12] => EMG chin[12]
    m = match(r"\s*emg\-subm(?<n>[12])\s*"i, l)
    l = isnothing(m) ? l : "emg chin$(m[:n])"

    # label = "EMG", transducer_type = "FP1-FP2" => label = "EEG FP1-FP2"
    l = (l == "emg" && t == "fp1-fp2") ? "eeg fp1-fp2" : l
    l = (l == "emg" && t == "fp2-fp1") ? "eeg fp2-fp1" : l

    # label = "EMG", transducer_type = "1A-1R" => label = "EMG chin1"
    l = (l == "emg" && t == "1a-1r") ? "emg chin1" : l

    # EKG

    # EKG1, ECG2, etc are ambiguous
    # pick same default as for "ECG"
    # TODO should I instead pick[B another default,
    #      or make a new ambiguous ECG signal type for these cases?
    m = match(r"[\s\[,]*e[ck]g([123])[\s\-]*e[ck]g([123])[\]\s,]*"i, l)
    l = isnothing(m) ? l : "ecg $(m[1])"

    m = match(r"[\s\[,]*e[ck]g([123])[\]\s,]*"i, l)
    l = isnothing(m) ? l : "ecg $(m[1])"

    # [LR] ECG
    m = match(r"^[\[\s,]*(?<lr>[lr])\s*E[ck]g"i, l)
    l = isnothing(m) ? l : "ecg av$(m[:lr])"

    # [LR]-Leg[12]?
    m = match(r"^[\[\s,]*(?<lr>[lr])\s*\-\s*leg[1-2][\s\],]?"i, l)
    l = isnothing(m) ? l : "ecg av$(m[:lr])"

    # EMG Leg

    # {left,right,l,r}[\s-_]*leg
    m = match(r"^(\s*emg\s*)?(left|l)[_\-\s]*leg\s*(?<rest>.*)\s*$"i, l)
    l = isnothing(m) ? l : "emg left_anterior_tibialis$(m[:rest])"
    m = match(r"^(\s*emg\s*)?(right|r)[_\-\s]*leg\s*(?<rest>.*)\s*$"i, l)
    l = isnothing(m) ? l : "emg right_anterior_tibialis$(m[:rest])"

    # leg[\s-_]*{left,right,l,r}
    m = match(r"^(\s*emg\s*)?(?<lr>left|l)[_\-\s]*leg\s*(?<rest>.*)\s*$"i, l)
    l = isnothing(m) ? l : "emg left_anterior_tibialis$(m[:rest])"
    m = match(r"^(\s*emg\s*)?(?<lr>right|r)[_\-\s]*leg\s*(?<rest>.*)\s*$"i, l)
    l = isnothing(m) ? l : "emg right_anterior_tibialis$(m[:rest])"

    # (Tib|Leg)(-|/)[LR]
    m = match(r"^\s*(leg|tib)[/\-](?<lr>l|left|right|r)\s*$"i, l)
    l = isnothing(m) ? l : "$(startswith(m[:lr], "l") ? "left" : "right")_anterior_tibialis"

    # [LR]Leg1 - [LR]Leg2
    m = match(r"[\s\[,]*(?<lr>[lr])leg([12]?)[\s\-lr]*leg([12]?)[\]\s,]*"i, l)
    l = isnothing(m) ? l : "emg $(m[:lr])leg"

    # [LR] LEG[12]?  # with a minus `-`, this would be interpreted as ECG
    m = match(r"^[\[\s,]*(?<lr>[lr])\s*leg[1234]?"i, l)
    l = isnothing(m) ? l : "emg leg$(m[:lr])"

    return l
end

custom_labels = deepcopy(OndaEDF.STANDARD_LABELS)
#custom_labels[["emg"]] = [p for p in custom_labels[["emg"]] if startswith(first(p), "chin")]

custom_extractors = [edf -> extract_channels_by_label(edf, signal_names, channel_names; preprocess_labels=test_preprocessor)
                     for (signal_names, channel_names) in custom_labels]

function has_leg(h)
    h.kind != "emg" && return false
    return any(c -> startswith(c, "left_anterior_tibialis") || startswith(c, "right_anterior_tibialis"), h.channels)
end

@testset "Import EDF" begin

    @testset "edf_to_samples_info" begin
        results = map(test_edf_to_samples_info) do r
            edf = mock_edf(r)
            return last(OndaEDF.edf_header_to_onda_samples_info(edf; custom_extractors=custom_extractors))
        end
        # print result of mapping `edf_to_onda_samples` over `test_edf_to_samples_info.in`
        # this makes it easy to see effects of any changes made to OndaEDF by looking at
        # `diff test_edf_to_samples_info.{in,out}`
        prettyprint_diagnostic_info("test_edf_to_samples_info", results)
        prettyprint_diagnostic_info("no_eeg_tested", filter(nt -> !any(h -> h.kind == "eeg", map(first, nt.header_map)), results))
        prettyprint_diagnostic_info("no_eog_tested", filter(nt -> !any(h -> h.kind == "eog", map(first, nt.header_map)), results))
        prettyprint_diagnostic_info("no_chin_tested", filter(nt -> !any(h -> startswith(h.kind, "emg") && (h.kind == "emg_ambiguous" || any(c -> startswith(c, "chin"), h.channels)), map(first, nt.header_map)), results))
        prettyprint_diagnostic_info("no_leg_tested", filter(nt -> !any(has_leg, map(first, nt.header_map)), results))
        prettyprint_diagnostic_info("no_ekg_tested", filter(nt -> !any(h -> h.kind ∈ Set(("ecg", "ekg")), map(first, nt.header_map)), results))
        for (i, (r, expected)) in enumerate(zip(results, test_edf_to_samples_info))
            @test (i, setdiff(r.unextracted_edf_headers, expected.unextracted_edf_headers)) == (i, [])
        end
    end

    n_records = 100
    edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)

    @testset "edf_to_onda_samples" begin
        returned_samples, nt = OndaEDF.edf_to_onda_samples(edf)
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

end
