@testset "EDF Export" begin

    n_records = 100
    edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)
    root = mktempdir()
    uuid = uuid4()

    onda_samples = edf_to_onda_samples(edf)
    annotations = edf_to_onda_annotations(edf, uuid)

    signal_names = ["eeg", "eog", "ecg", "emg", "heart_rate", "tidal_volume",
                    "respiratory_effort", "snore", "positive_airway_pressure",
                    "pap_device_leak", "pap_device_cflow", "sao2", "ptaf"]
    signals_to_export = onda_samples[indexin(signal_names, getproperty.(getproperty.(onda_samples, :info), :kind))]
    exported_edf = onda_to_edf(signals_to_export, annotations)
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
        eeg_signal = only(filter(row -> row.kind == "eeg", returned_signals))
        ecg_signal = only(filter(row -> row.kind == "ecg", returned_signals))
        
        massive_eeg = Tables.rowmerge(eeg_signal; sample_rate=5000.0)
        @test OndaEDF.edf_record_metadata([massive_eeg]) == (1000000, 1 / 5000)

        chunky_eeg = Tables.rowmerge(eeg_signal; sample_rate=9999.0)
        chunky_ecg = Tables.rowmerge(ecg_signal; sample_rate=425.0)
        @test_throws OndaEDF.RecordSizeException OndaEDF.edf_record_metadata([chunky_eeg, chunky_ecg])

        e_notation_eeg = Tables.rowmerge(eeg_signal; sample_rate=20_000_000.0)
        @test OndaEDF.edf_record_metadata([e_notation_eeg]) == (4.0e9, 1 / 20_000_000)

        too_big_and_thorny_eeg = Tables.rowmerge(eeg_signal; sample_rate=20_576_999.0)
        @test_throws OndaEDF.EDFPrecisionError OndaEDF.edf_record_metadata([too_big_and_thorny_eeg])

        floaty_eeg = Tables.rowmerge(eeg_signal; sample_rate=256.5)
        floaty_ecg = Tables.rowmerge(ecg_signal; sample_rate=340)
        @test OndaEDF.edf_record_metadata([floaty_eeg, floaty_ecg]) == (100, 2)

        resizable_eeg = Tables.rowmerge(eeg_signal; sample_rate=25.25)
        resizable_ecg = Tables.rowmerge(ecg_signal; sample_rate=10.4)
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
        uuid = uuid4() # call this here because `@testset` resets global RNG, so we'll
        # get a conflict with the existing UUID if we let `import_edf!`
        # generate it without "advancing" the RNG
        round_tripped = edf_to_onda_annotations(exported_edf, uuid)
        
        @test round_tripped isa Vector{<:Onda.Annotation}
        # annotations are sorted by start time on export
        ann_sorted = sort(annotations; by=row -> Onda.start(row.span))
        @test getproperty.(round_tripped, :span) == getproperty.(ann_sorted, :span)
        @test getproperty.(round_tripped, :value) == getproperty.(ann_sorted, :value)
        # new UUID for recording is created during import
        @test all(getproperty.(round_tripped, :recording) .!= getproperty.(ann_sorted, :recording))
        # new UUID for each annotation created during import
        @test all(getproperty.(round_tripped, :id) .!= getproperty.(ann_sorted, :id))
    end

end
