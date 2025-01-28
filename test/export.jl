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
    @testset "export $signal_name" for signal_name in signal_names
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
            # sparse CSC but for wide data we have a huge column pointer
            # so transposing to get sparse CSR
            new_data = spzeros(eltype(samples.data), Onda.index_from_time(sample_rate, Onda.duration(samples)) - 1, channel_count(samples))'
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

        @testset "$(samples_orig.info.sensor_type)" for (samples_orig, signal_round_tripped) in zip(onda_samples, nt.signals)
            info_orig = samples_orig.info
            info_round_tripped = SamplesInfoV2(signal_round_tripped)

            # anything else, the encoding parameters may change on export
            if info_orig.sample_type == "int16"
                @test info_orig == info_round_tripped
            end

            samples_rt = Onda.load(signal_round_tripped)
            @test all(isapprox.(decode(samples_orig).data, decode(samples_rt).data;
                                atol=info_orig.sample_resolution_in_unit))
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

        onda_ints = filter(x -> x <: Integer, onda_types)
        onda_floats = filter(x -> x <: AbstractFloat, onda_types)
        @test issetequal(union(onda_ints, onda_floats), onda_types)

        # test that we can encode ≈ the full range of values expressible in each
        # possible Onda sample type.
        @testset "encoding $T, resolution $res" for T in onda_types, res in (-0.2, 0.2)
            info = SamplesInfoV2(; sensor_type="x",
                                 channels=["x"],
                                 sample_unit="microvolt",
                                 sample_resolution_in_unit=res,
                                 sample_offset_in_unit=1,
                                 sample_type=T,
                                 sample_rate=1)

            if T <: AbstractFloat
                min = nextfloat(typemin(T))
                max = prevfloat(typemax(T))
                data = range(min, max; length=9)
            else
                min = typemin(T)
                max = typemax(T)
                step = max ÷ T(8) - min ÷ T(8)
                data = range(min, max; step)
            end

            data = reshape(data, 1, :)
            samples = Samples(data, info, true)
            samples = Onda.decode(samples)

            # for  r e a s o n s  we need to be a bit careful with just how large
            # the values are that we're trying to use; EDF.jl (and maybe EDF
            # generally, unclear) can't handle physical min/max more than like
            # 1e8 (actually for EDF.jl it's 99999995 because Float32 precision).
            # so, we try to do typemax/min of the encoded type, and if that
            # leads to physical min/max that are too big, we clamp and
            # re-encode.
            if !all(<(1e10) ∘ abs ∘ float, decode(samples).data)
                @info "clamped decoded $(T) samples to ±1e10"
                min_d, max_d = -1e10, 1e10
                data_d = reshape(range(min_d, max_d; length=9), 1, :)
                samples = Onda.encode(Samples(data_d, info, false))
            end

            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))

            @test vec(decode(samples).data) ≈ EDF.decode(signal)
        end

        @testset "skip reencoding (res = $res)" for res in (-2, 2)
            info = SamplesInfoV2(; sensor_type="x",
                                 channels=["x"],
                                 sample_unit="microvolt",
                                 sample_resolution_in_unit=res,
                                 sample_offset_in_unit=1,
                                 sample_type=Int32,
                                 sample_rate=1)

            data = Int32[typemin(Int16) typemax(Int16)]

            samples = Samples(data, info, true)
            # data is re-used if already encoded
            samples_reenc = OndaEDF.reencode_samples(samples, Int16)
            @test samples_reenc.data === samples.data
            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))
            @test EDF.decode(signal) == vec(decode(samples).data)

            # make sure it works with decoded too
            samples_dec = Onda.decode(samples)
            samples_dec_reenc = OndaEDF.reencode_samples(samples_dec, Int16)
            @test samples_dec_reenc.data !== samples_reenc.data
            @test encode(samples_dec_reenc).data == encode(samples).data
            @test samples_dec_reenc == samples_reenc
            signal2 = only(OndaEDF.onda_samples_to_edf_signals([samples_dec], 1.0))
            @test EDF.decode(signal2) == vec(samples_dec.data)

            # bump just outside the range representable as Int16
            samples = Samples(data .+ Int32[-1 1], info, true)
            samples_reenc = OndaEDF.reencode_samples(samples, Int16)
            # make sure encoding has changed:
            @test encode(samples_reenc).data != encode(samples).data
            # but actual stored values have not
            @test decode(samples_reenc).data == decode(samples).data

            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))
            @test EDF.decode(signal) == vec(decode(samples).data)

            # make sure it works with decoded too
            samples_dec = decode(samples)
            samples_dec_reenc = OndaEDF.reencode_samples(samples_dec, Int16)
            @test encode(samples_dec_reenc).data == encode(samples_reenc).data
            # different encoding
            @test encode(samples_dec_reenc).data != encode(samples).data
            # ... that's teh same as passing in encoded samples
            @test encode(samples_dec_reenc).data == encode(samples_reenc).data
            # same decoded values
            @test decode(samples_dec_reenc).data == decode(samples).data

            signal3 = only(OndaEDF.onda_samples_to_edf_signals([Onda.decode(samples)], 1.0))
            @test EDF.decode(signal3) == vec(decode(samples).data)

            # UInt64
            uinfo = SamplesInfoV2(Tables.rowmerge(info; sample_type="uint64"))
            data = UInt64[0 typemax(Int16)]
            samples = Samples(data, uinfo, true)
            samples_reenc = OndaEDF.reencode_samples(samples, Int16)
            @test samples_reenc.data === samples.data
            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))
            @test EDF.decode(signal) == vec(decode(samples).data)

            samples.data .+= UInt64[0 1]
            samples_reenc = OndaEDF.reencode_samples(samples, Int16)
            @test samples_reenc != samples
            @test encode(samples_reenc).data != encode(samples).data
            # due to FMA and other floating point details, this may not be exactly equal
            # but it should be very close. Elementwise approximate equality is a stronger
            # requirement than matrix approximate equality
            @test all(isapprox.(decode(samples_reenc).data, decode(samples).data; atol=1e-12))

            signal = only(OndaEDF.onda_samples_to_edf_signals([samples], 1.0))
            @test EDF.decode(signal) == vec(decode(samples).data)
        end
    end

    @testset "`reencode_samples` edge case: constant data" begin
        # Weird encoding
        info = SamplesInfoV2(; sensor_type="x",
            channels=["x"],
            sample_unit="microvolt",
            sample_resolution_in_unit=0.001,
            sample_offset_in_unit=0,
            sample_type=Float64,
            sample_rate=1)

        data = zeros(UInt64, 1, 2) .+ 0x02
        samples = Samples(data, info, false)
        samples_reenc = OndaEDF.reencode_samples(samples)
        @test samples_reenc isa Samples
        @test decode(samples_reenc).data == data
    end

end
