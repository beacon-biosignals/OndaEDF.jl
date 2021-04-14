using Test, Dates, Random, UUIDs, Statistics
using OndaEDF, Onda, EDF

@testset "EDF.Signal label handling" begin
    signal_names = ["eeg", "eog", "test"]
    canonical_names = OndaEDF.STANDARD_LABELS[["eeg"]]
    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", signal_names, "c3", canonical_names) == "c3-m1_plus_a2_over_2"
    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", ["ecg"], "c3", canonical_names) == nothing
    @test OndaEDF.match_edf_label("EEG C3-(M1 +A2)/2 - rEf3", signal_names, "c4", canonical_names) == nothing
    @test OndaEDF.match_edf_label(" TEsT   -Fpz  -REF-cpz", signal_names, "fpz", canonical_names) == "-fpz-ref-cpz"
    @test OndaEDF.match_edf_label(" TEsT   -Fpz  -REF-cpz", signal_names, "fp", canonical_names) == nothing
    @test OndaEDF.match_edf_label("  -Fpz  -REF-cpz", signal_names, "fpz", canonical_names) == nothing
    @test OndaEDF.match_edf_label("EOG L", signal_names, "left", OndaEDF.STANDARD_LABELS[["eog"]]) == "left"
    @test OndaEDF.match_edf_label("EOG R", signal_names, "right", OndaEDF.STANDARD_LABELS[["eog"]]) == "right"
    for (signal_names, channel_names) in OndaEDF.STANDARD_LABELS
        for channel_name in channel_names
            name = channel_name isa Pair ? first(channel_name) : channel_name
            x = OndaEDF.match_edf_label("EKGR", signal_names, name, channel_names)
            @test name == "avr" ? x == "avr" : x == nothing
        end
    end
    @test OndaEDF.export_edf_label("eeg", "t4") == "EEG T4-Ref"
    @test OndaEDF.export_edf_label("eeg", "t4-a1") == "EEG T4-A1"
    @test OndaEDF.export_edf_label("emg", "lat") == "EMG LAT"
end

function test_edf_signal(rng, label, transducer, physical_units,
                         physical_min, physical_max,
                         digital_min, digital_max,
                         samples_per_record, n_records)
    header = EDF.SignalHeader(label, transducer, physical_units,
                              physical_min, physical_max,
                              digital_min, digital_max,
                              "", Int16(samples_per_record))
    samples = rand(rng, Int16, n_records * samples_per_record)
    return EDF.Signal(header, samples)
end

function make_test_data(rng, sample_rate, samples_per_record, n_records)
    imin16, imax16 = Float32(typemin(Int16)), Float32(typemax(Int16))
    anns_1 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, i + 1, ["", "$i a", "$i b"])] for i in 1:n_records]
    anns_2 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, 0, ["", "$i c", "$i d"])] for i in 1:n_records]
    edf_signals = Union{EDF.AnnotationsSignal,EDF.Signal}[
        test_edf_signal(rng, "EEG F3-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG F4-M1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG C3-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG O1-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "C4-M1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "O2-A1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "E1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "E2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Fpz",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        EDF.AnnotationsSignal(samples_per_record, anns_1)
        test_edf_signal(rng, "EMG LAT",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EMG RAT",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "SNORE", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "IPAP", "", "cmH2O", -74.0465f0, 74.19587f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EPAP", "", "cmH2O", -73.5019f0, 74.01962f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "CFLOW", "",  "LPM", -309.153f0, 308.8513f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "PTAF", "",     "v", -125.009f0, 125.009f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Leak", "",   "LPM", -147.951f0, 148.4674f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "CHEST", "E",  "uV", -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "ABD", "E",    "uV", -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Tidal", "",   "mL", -4928.18f0, 4906.871f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "SaO2", "",    "%",       0.0f0,    100.0f0,  imin16, imax16, samples_per_record, n_records)
        EDF.AnnotationsSignal(samples_per_record, anns_2)
        test_edf_signal(rng, "EKG EKGR- REF", "E",  "uV",   -9324.0f0, 2034.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "IC", "E",    "uV",    -32768.0f0, 32767.0f0, imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "HR", "",    "BpM",    -32768.0f0, 32768.0f0, imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EcG EKGL", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "- REF", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "REF1", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
    ]
    seconds_per_record = samples_per_record / sample_rate
    edf_header = EDF.FileHeader("0", "", "", DateTime("2014-10-27T22:24:28"), true, n_records, seconds_per_record)
    edf = EDF.File((io = IOBuffer(); close(io); io), edf_header, edf_signals)
    return edf, Dict(:eeg => [9, 1, 2, 3, 5, 4, 6],
                     :eog => [7, 8],
                     :ecg => [27, 24],
                     :emg => [25, 11, 12],
                     :heart_rate => [26],
                     :tidal_volume => [21],
                     :respiratory_effort => [19, 20],
                     :snore => [13],
                     :positive_airway_pressure => [14, 15],
                     :pap_device_leak => [18],
                     :pap_device_cflow => [16],
                     :sao2 => [22],
                     :ptaf => [17])
end

n_records = 100
edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)
root = mktempdir()
uuid = uuid4()
returned_uuid, (returned_signals, annotations) = import_edf!(root, edf, uuid)

@testset "import_edf!" begin
    @test returned_uuid == uuid
    @test length(returned_signals) == 13
    signals = Dict(s.kind => s for s in returned_signals)
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

    for signal in values(signals)
        @test signal.span.start == Nanosecond(0)
        @test signal.span.stop == Nanosecond(Second(200))
        @test signal.file_format == "lpcm.zst"
    end

    for (signal_name, edf_indices) in edf_channel_indices
        onda_samples = load(signals[string(signal_name)]).data
        edf_samples = mapreduce(transpose ∘ EDF.decode, vcat, edf.signals[edf_indices])
        @test isapprox(onda_samples, edf_samples, rtol=0.02)
    end

    @test length(annotations) == n_records * 4
    for i in 1:n_records
        start = Nanosecond(Second(i))
        stop = start + Nanosecond(Second(i + 1))
        @test any(a -> a.value == "$i a" && a.span.start == start && a.span.stop == stop, annotations) #Onda.Annotation("$i a", start, stop) in annotations
        @test any(a -> a.value == "$i b" && a.span.start == start && a.span.stop == stop, annotations) #Onda.Annotation("$i b", start, stop) in annotations
        @test any(a -> a.value == "$i c" && a.span.start == start && a.span.stop == start + Nanosecond(1), annotations) #Onda.Annotation("$i c", start, start) in annotations
        @test any(a -> a.value == "$i d" && a.span.start == start && a.span.stop == start + Nanosecond(1), annotations) #Onda.Annotation("$i d", start, start) in annotations
    end
end

@testset "export_edf" begin
    signal_names = ["eeg", "eog", "ecg", "emg", "heart_rate", "tidal_volume",
                    "respiratory_effort", "snore", "positive_airway_pressure",
                    "pap_device_leak", "pap_device_cflow", "sao2", "ptaf"]
    signals_to_export = returned_signals[indexin(signal_names, getproperty.(returned_signals, :kind))]
    exported_edf = export_edf(signals_to_export, annotations)
    @test exported_edf.header.record_count == 200
    offset = 0
    for signal_name in signal_names
        onda_signal = only(filter(row -> row.kind == signal_name, returned_signals))
        channel_names = onda_signal.channels
        edf_indices = (1:length(channel_names)) .+ offset
        offset += length(channel_names)
        onda_samples = Onda.load(onda_signal).data
        edf_samples = mapreduce(transpose ∘ EDF.decode, vcat, exported_edf.signals[edf_indices])
        @test isapprox(onda_samples, edf_samples, rtol=0.02)
        for (i, channel_name) in zip(edf_indices, channel_names)
            s = exported_edf.signals[i]
            @test s.header.label == OndaEDF.export_edf_label(signal_name, channel_name)
            @test s.header.physical_dimension == OndaEDF.onda_to_edf_unit(onda_signal.sample_unit)
        end
    end
    @testset "Record metadata" begin
        massive_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=5000.0)
        @test OndaEDF.edf_record_metadata([massive_eeg]) == (1000000, 1 / 5000)

        chunky_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=9999.0)
        chunky_ecg = signal_from_template(recording.signals[:ecg]; sample_rate=425.0)
        @test_throws OndaEDF.RecordSizeException OndaEDF.edf_record_metadata([chunky_eeg, chunky_ecg])

        e_notation_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=20_000_000.0)
        @test OndaEDF.edf_record_metadata([e_notation_eeg]) == (4.0e9, 1 / 20_000_000)

        too_big_and_thorny_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=20_576_999.0)
        @test_throws OndaEDF.EDFPrecisionError OndaEDF.edf_record_metadata([too_big_and_thorny_eeg])

        floaty_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=256.5)
        floaty_ecg = signal_from_template(recording.signals[:ecg]; sample_rate=340)
        @test OndaEDF.edf_record_metadata([floaty_eeg, floaty_ecg]) == (100, 2)

        resizable_eeg = signal_from_template(recording.signals[:eeg]; sample_rate=25.25)
        resizable_ecg = signal_from_template(recording.signals[:ecg]; sample_rate=10.4)
        @test OndaEDF.edf_record_metadata([resizable_eeg, resizable_ecg]) == (10, 20)

        @testset "Exception and Error handling" begin
            messages = ("RecordSizeException: sample rates [9999.0, 425.0] cannot be resolved to a data record size smaller than 61440 bytes",
                        "EDFPrecisionError: String representation of value 2.0576999e7 is longer than 8 ASCII characters")
            exceptions = (OndaEDF.RecordSizeException([chunky_eeg, chunky_ecg]), OndaEDF.EDFPrecisionError(20576999.0))
            for (message, exception) in zip(messages, exceptions)
                buffer = IOBuffer()
                showerror(buffer, exception)
                @test String(take!(buffer)) == message
            end
        end
    end
    @testset "annotation import/export via round trip" begin
        uuid4() # call this here because `@testset` resets global RNG, so we'll
        # get a conflict with the existing UUID if we let `import_edf!`
        # generate it without "advancing" the RNG
        testuuid, round_tripped = import_edf!(dataset, exported_edf)
        @test round_tripped isa Onda.Recording
        @test dataset.recordings[uuid].annotations == round_tripped.annotations
    end
end
