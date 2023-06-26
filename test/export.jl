@testset "EDF Export" begin

    n_records = 100
    edf, edf_channel_indices = make_test_data(MersenneTwister(42), 256, 512, n_records)
    uuid = uuid4()

    onda_samples, plan = edf_to_onda_samples(edf)
    annotations = edf_to_onda_annotations(edf, uuid)

    signal_names = ["eeg", "eog", "ecg", "emg", "heart_rate", "tidal_volume",
                    "respiratory_effort", "snore", "positive_airway_pressure",
                    "pap_device_leak", "pap_device_cflow", "sao2", "ptaf"]
    samples_to_export = onda_samples[indexin(signal_names, getproperty.(getproperty.(onda_samples, :info), :sensor_type))]
    exported_edf = onda_to_edf(samples_to_export, annotations)
    @test exported_edf.header.record_count == 200
    offset = 0
    for signal_name in signal_names
        samples = only(filter(s -> s.info.sensor_type == signal_name, onda_samples))
        channel_names = samples.info.channels
        edf_indices = (1:length(channel_names)) .+ offset
        offset += length(channel_names)
        samples_data = Onda.decode(samples).data
        edf_samples = mapreduce(transpose ∘ EDF.decode, vcat, exported_edf.signals[edf_indices])
        @test isapprox(samples_data, edf_samples; rtol=0.02)
        for (i, channel_name) in zip(edf_indices, channel_names)
            s = exported_edf.signals[i]
            @test s.header.label == OndaEDF.export_edf_label(signal_name, channel_name)
            @test s.header.physical_dimension == OndaEDF.onda_to_edf_unit(samples.info.sample_unit)
        end
    end
    @testset "Record metadata" begin
        function change_sample_rate(samples; sample_rate)
            info = SamplesInfoV2(Tables.rowmerge(samples.info; sample_rate=sample_rate))
            new_data = similar(samples.data, 0, Onda.index_from_time(sample_rate, Onda.duration(samples)) - 1)
            return Samples(new_data, info, samples.encoded; validate=false)
        end

        eeg_samples = only(filter(row -> row.info.sensor_type == "eeg", onda_samples))
        ecg_samples = only(filter(row -> row.info.sensor_type == "ecg", onda_samples))

        massive_eeg = change_sample_rate(eeg_samples, sample_rate=5000.0)
        @test OndaEDF.edf_record_metadata([massive_eeg]) == (1000000, 1 / 5000)

        chunky_eeg = change_sample_rate(eeg_samples; sample_rate=9999.0)
        chunky_ecg = change_sample_rate(ecg_samples; sample_rate=425.0)
        @test_throws OndaEDF.RecordSizeException OndaEDF.edf_record_metadata([chunky_eeg, chunky_ecg])

        e_notation_eeg = change_sample_rate(eeg_samples; sample_rate=20_000_000.0)
        @test OndaEDF.edf_record_metadata([e_notation_eeg]) == (4.0e9, 1 / 20_000_000)

        too_big_and_thorny_eeg = change_sample_rate(eeg_samples; sample_rate=20_576_999.0)
        @test_throws OndaEDF.EDFPrecisionError OndaEDF.edf_record_metadata([too_big_and_thorny_eeg])

        floaty_eeg = change_sample_rate(eeg_samples; sample_rate=256.5)
        floaty_ecg = change_sample_rate(ecg_samples; sample_rate=340)
        @test OndaEDF.edf_record_metadata([floaty_eeg, floaty_ecg]) == (100, 2)

        resizable_eeg = change_sample_rate(eeg_samples; sample_rate=25.25)
        resizable_ecg = change_sample_rate(ecg_samples; sample_rate=10.4)
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
        round_tripped = edf_to_onda_annotations(exported_edf, uuid)

        @test round_tripped isa Vector{EDFAnnotationV1}
        # annotations are sorted by start time on export
        ann_sorted = sort(annotations; by=row -> Onda.start(row.span))
        @test getproperty.(round_tripped, :span) == getproperty.(ann_sorted, :span)
        @test getproperty.(round_tripped, :value) == getproperty.(ann_sorted, :value)
        # same recording UUID passed as original:
        @test getproperty.(round_tripped, :recording) == getproperty.(ann_sorted, :recording)
        # new UUID for each annotation created during import
        @test all(getproperty.(round_tripped, :id) .!= getproperty.(ann_sorted, :id))
    end

    @testset "full service" begin
        # import annotations
        nt = store_edf_as_onda(exported_edf, mktempdir(), uuid)
        @test nt.annotations isa Vector{EDFAnnotationV1}
        # annotations are sorted by start time on export
        ann_sorted = sort(annotations; by=row -> Onda.start(row.span))
        @test getproperty.(nt.annotations, :span) == getproperty.(ann_sorted, :span)
        @test getproperty.(nt.annotations, :value) == getproperty.(ann_sorted, :value)
        # same recording UUID passed as original:
        @test getproperty.(nt.annotations, :recording) == getproperty.(ann_sorted, :recording)
        # new UUID for each annotation created during import
        @test all(getproperty.(nt.annotations, :id) .!= getproperty.(ann_sorted, :id))

        for (samples_orig, signal_round_tripped) in zip(onda_samples, nt.signals)
            info_orig = samples_orig.info
            info_round_tripped = SamplesInfoV2(signal_round_tripped)
            for p in setdiff(propertynames(info_orig),
                             (:edf_channels, :sample_type, :sample_resolution_in_unit))
                @test getproperty(info_orig, p) == getproperty(info_round_tripped, p)
            end
            if info_orig.sample_type == "int32"
                resolution_orig = info_orig.sample_resolution_in_unit * 2
            else
                resolution_orig = info_orig.sample_resolution_in_unit
            end
            @test resolution_orig ≈ info_round_tripped.sample_resolution_in_unit
        end

        # don't import annotations
        nt = store_edf_as_onda(exported_edf, mktempdir(), uuid; import_annotations=false)
        @test nt.annotations isa Vector{EDFAnnotationV1}
        @test length(nt.annotations) == 0

        # import empty annotations
        exported_edf2 = onda_to_edf(samples_to_export)
        @test_logs (:warn, r"No annotations found in") store_edf_as_onda(exported_edf2, mktempdir(), uuid; import_annotations=true)
    end

    @testset "re-encoding" begin
        _flatten_union(T::Union) = vcat(T.a, _flatten_union(T.b))
        _flatten_union(T::Type) = T

        onda_types = _flatten_union(Onda.LPCM_SAMPLE_TYPE_UNION)

        # test that we can encode the full range of values expressible in each
        # possible Onda sample type.
        #
        @testset "encoding $T" for T in onda_types
            info = SamplesInfoV2(; sensor_type="x",
                                 channels=["x"],
                                 sample_unit="microvolt",
                                 sample_resolution_in_unit=2,
                                 sample_offset_in_unit=1,
                                 sample_type=T,
                                 sample_rate=1)

            min = typemin(T)
            max = typemax(T)

            if T <: AbstractFloat
                min = nextfloat(min)
                max = prevfloat(max)
            end

            data = range(min, max; length=9)
            data = T <: AbstractFloat ? data : round.(T, data)
            data = reshape(data, 1, :)

            samples = Samples(data, info, true)

            # for r e a s o n s we need to be a bit careful with just how large
            # the values are that we're trying to use; EDF.jl (and maybe EDF
            # generally, unclear) can't handle physical min/max more than like
            # 1e8 (actually for EDF.jl it's 99999995 because Float32 precision).
            # so, we try to do typemax/min of the encoded type, and if that
            # leads to physical min/max that are too big, we clamp and
            # re-encode.
            if !all(<(1e10) ∘ abs ∘ float, decode(samples).data)
                min_d, max_d = -1e10, 1e10
                data_d = reshape(range(min_d, max_d; length=9), 1, :)
                samples = Onda.encode(Samples(data_d, info, false))
            end

            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))

            @test vec(decode(samples).data) ≈ EDF.decode(signal)
        end
    end

end
