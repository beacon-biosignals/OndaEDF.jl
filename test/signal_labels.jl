@testset "EDF.Signal label handling (uppercased: $upper)" for upper in (false, true)
    labels = OndaEDF.STANDARD_LABELS
    signal_names = ["eeg", "eog", "test"]
    if upper
        labels = Dict(fmap(uppercase, collect(labels)))
        signal_names = uppercase.(signal_names)
    end

    canonical_names = labels[upper ? ["EEG"] : ["eeg"]]

    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", signal_names, "c3", canonical_names) == "c3-m1_plus_a2_over_2"
    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", ["ecg"], "c3", canonical_names) == nothing
    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", signal_names, "c4", canonical_names) == nothing
    @test OndaEDF.match_edf_label(" TEsT   -Fpz  -REF-cpz", signal_names, "fpz", canonical_names) == "-fpz-ref-cpz"
    @test OndaEDF.match_edf_label(" TEsT   -Fpz  -REF-cpz", signal_names, "fp", canonical_names) == nothing
    @test OndaEDF.match_edf_label("  -Fpz  -REF-cpz", signal_names, "fpz", canonical_names) == "-fpz-ref-cpz"

    canonical_eye_names = labels[upper ? ["EOG", "EEG"] : ["eog", "eeg"]]
    @test OndaEDF.match_edf_label("EOG L", signal_names, "left", canonical_eye_names) == "left"
    @test OndaEDF.match_edf_label("EOG R", signal_names, "right", canonical_eye_names) == "right"
    for (signal_names, channel_names) in labels
        for channel_name in channel_names
            name = channel_name isa Pair ? first(channel_name) : channel_name
            x = OndaEDF.match_edf_label("EKGR", signal_names, name, channel_names)
            @test lowercase(name) == "avr" ? x == "avr" : x == nothing
        end
    end
    @test OndaEDF.export_edf_label("eeg", "t4") == "EEG T4-Ref"
    @test OndaEDF.export_edf_label("eeg", "t4-a1") == "EEG T4-A1"
    @test OndaEDF.export_edf_label("emg", "lat") == "EMG LAT"
end
