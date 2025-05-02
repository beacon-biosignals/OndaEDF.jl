# An Opinionated Guide to Converting EDFs to Onda

## Basic workflow

At a high level, the basic workflow for EDF-to-Onda conversion is iterative:
1. Formulate a "plan" which specifies how to convert the metadata associated with each `EDF.Signal` into Onda metadata (channel names, quantization/encoding parameters, etc.)
2. Review the plan, making sure that all necessary `EDF.Signal`s will be extracted, and that the quantization, sample rate, physical units, etc. are reasonable.
3. Revise the plan as needed, repeating steps 1-2 until you're happy.
4. Execute the plan, loading all EDF signal data if necessary and converting into `Onda.Samples`
5. Review the executed plan for additional errors or issues, and iterate steps 1-4 as needed.

In the following sections, we expand on the philosophy behind OndaEDF's EDF-to-Onda design and present some detailed, opinionated workflows for converting a single EDF and multiple EDFs.

## Philosophy

The motivation for separating the planning and execution is threefold.

First, while there is an [EDF(+) specification](https://www.edfplus.info/specs/index.html),  it's so commonly violated in so many various ways that an EDF conversion package that _requires_ fully spec-compliant EDFs is of little practical use, but at the same time, anticipating and working around all these possible violations is not practical.
Separating planning and execution during EDF-to-Onda conversion reverts more control to the user for how their _particular_ EDF files are handled.

Second, making the plan a separate intermediate output means that not only can it be reviewed during conversion but can be persisted as a record of how any EDF-derived Onda signals were converted.
This kind of provenance information is very useful when investigating issues with a dataset that may crop up long after the initial conversion.

Third, planning only requires that the _headers_ of the `EDF.Signal`s be read into memory, thereby separating the iterative part of the conversion process from the expensive, one-time step which requires _all_ the signal data be read into memory.
This enables workflows that would be impractical otherwise, like planning bulk conversion of thousands of EDFs at once.
When dealing with large, messy datasets, we have found that metadata issues are both likely to occur and likely to be _different_ across individual EDFs.
This makes normalizing the EDF metadata one file at a time extremely tedious, since the metadata issues encountered in a single file may not be representative of the rest of the dataset.
Thus, in practice it's better to deal with EDF metadata conversion in _bulk_, and the plan-then-execute workflow enables users to deal with these issues all at once, save out the plan, and then distribute the actual conversion work to as many workers as necessary to execute it in a reasonable timeframe.

## Converting a single EDF to Onda

The following steps assume you have read an EDF file into memory with `EDF.read` or otherwise created an `EDF.File`.
After the detailed workflow for converting a single EDF file to Onda format, we'll discuss how to handle batches of EDF files.

### Generate a plan

This is straightforward, using [`plan_edf_to_onda_samples`](@ref).
As outlined in the documentation for [`plan_edf_to_onda_samples`](@ref), a "plan" is a table with one row per `EDF.Signal`, which contains all the fields from the signal's header as well as the fields of the `Onda.SamplesInfoV2` that will be generated when the plan is executed (with the caveat that the `:channels` field is called `:channel` to indicate that it corresponds to a single channel in the output).
It also contains a few additional fields for defining the mapping between EDF and Onda signal indices, as well as a field to capture any errors thrown during planning (or, more likely, during execution of the plan):
- `:edf_signal_index`, the 1-based numerical index of the source signal in `edf.signals`.
- `:sensor_label`, a file-unique unique label for this group of channels (may be `missing`).
- `:recording`, an optional UUID of the recording procedure these signals should be associated with.
- `:error`, any errors that were caught during planning and/or execution.

### Review the plan.

Check for EDF signals whose `label` or `physical_dimension` could not be matched using the standard OndaEDF labels and units, as indicated by `missing` values in the `channel`/`sensor_type` (for un-matched `label`) or `sample_unit` (for un-matched `physical_dimension`).
It's also a good idea at this point to review the other EDF signal header fields, and how they will be converted to Onda (especially the sample unit, resolution and offset, which correspond to the physical/digital minimum/maximum from the EDF signal header.)
It's harder to fix these issues with the numerical signal header fields as they usually point to issues with how the data was encoded into an EDF initially.
However, it's still better to detect and document any issues with the underlying EDF data at this stage to prevent nasty surprises down the road.

### Revise the plan

If there are EDF signals with un-matched `label` or `physical_dimension`, you have a few options.
We recommend you consider them in roughly this order.

#### Skip them

The first option to consider is to simply ignore these signals; not all signals are necessarily required for downstream use, and converting each and every signal in an EDF may be more work than is justified!

#### Provide custom labels and units

The second option you have is to provide custom `labels=` and `units=` keyword arguments to [`plan_edf_to_onda_samples`](@ref).
For unambiguous, [spec-compliant](https://www.edfplus.info/specs/edftexts.html#label_physidim) `label`s and `physical_dimension`s, it's generally possible to create custom `label=` or `unit=` specifications to match them.

!!! note
    Custom labels should be specified as _lowercase_, without reference, and without the sensor type prefix.
    So to match a label like `"EEG R1-Ref"`, use a label like `"eeg" => ["r1"]`, and not `"EEG" => ["R1"]` or `"eeg" => ["r1-ref"]`.
    See the documentation for [`plan_edf_to_onda_samples`](@ref) for more details, and the internal [`OndaEDF.match_edf_label`](@ref) for low-level details of how labels are matched.

!!! warning
    Sometimes EDF `label`s are ambiguous and can be matched by multiple different OndaEDF `label=` specifications.
    Matching is greedy, in that the first label specification that matches is used regardless of any other possible matches, so you should add your custom labels to the end of an existing set, as in

    ```julia
    my_labels = collect(pairs(OndaEDF.STANDARD_LABELS))
    push!(my_labels, ["eog"] => ["left" => "eyeleft", "right" => "eyeright"])
    ```

    When using custom labels, make sure that they haven't accidentally changed how other `label`s are matched by reviewing the plan for any unintended changes.

##### Example: non-EDF+-compliant label with channel followed by signal type

OndaEDF will be confused by a label like `CHIN EMG` using the default labels.  This label does not conform to the [EDF+ specification for labels and physical dimensions](https://www.edfplus.info/specs/edftexts.html#label_physidim), which

> consists of three components, from left to right:
>
> - Type of signal (for example EEG).
> - A space.
> - Specification of the sensor (for example Fpz-Cz).

To match this kind of label, we can use a custom label specification like so:

```
chin_label = ["emg", "chin"] => ["chin" => ["emg"]]
my_labels = push!(collect(pairs(OndaEDF.STANDARD_LABELS)), chin_label)
plan = plan_edf_to_onda_samples(edf; labels=my_labels)
```

To break this label specification down:

- `["emg", "chin"]`: indicates that this specification is for `sensor_type` of `"emg"`, for which `"chin"` is accepted as a non-canonical alternative.
- `["chin" => ["emg"]]` specifies that there's _one_ possible channel for this sensor type, whose canonical label (used in the output) is `"chin"`, but for which an alternative of `"emg"` is accepted.

This essentially tricks OndaEDF into treating `CHIN EMG` as sensor type of "`CHIN` (alternative for sensor type of `EMG`), and channel label "`EMG` (alternative way to specify `CHIN`)".  For more details on how this matching is carried out, see [`plan_edf_to_onda_samples`](@ref) and the internal [`OndaEDF.match_edf_label`](@ref).

#### Preprocess signal headers

The third option, for signals that _must_ be converted and cannot be handled with custom labels (without undue hassle) is to pre-process the signal headers before generating the plan.
While the canonical input to `plan_edf_to_onda_samples` is an `EDF.File`, the header-matching logic operates fundamentally one signal header at a time.
Moreover, it does not actually require that the input _be_ an `EDF.SignalHeader`, only that it have the same _fields_ as an `EDF.SignalHeader`.
This design decision is meant to support workflows where the signal headers cannot for some reason be processed as-is due to corrupt/malformed strings, labels that cannot be matched using the OndaEDF matching algorithm, or any other reason.

For example, we've encountered EDFs in the wild where the `transducer_type` and `label` fields are switched, and must be switched back before planning:

```julia
edf = EDF.File(my_edf_file_path)

function corrected_header(signal::EDF.Signal)
    header = signal.header
    return Tables.rowmerge(header;
                           label=header.transducer_type,
                           transducer_type=header.label)
end

plans = map(plan_edf_to_onda_samples ∘ corrected_header, edf.signals)
new_plan = plan_edf_to_onda_samples_groups(plans)
```

Note that an additional step of `plan_edf_to_onda_samples_groups` is required after planning the individual signals.
This is due to the fact that EDF is a "single channel" format, where each signal is only a single channel, while Onda is a "multichannel" format where a signal can have mmultiple channels as long as the sampling rate, quantization, and other metadata are consistent.
Normally, calling `plan_edf_to_onda_samples` with an `EDF.File` will do this grouping for you, but when planning individually pre-processed signal headers, we have to do it ourselves at the end.

#### Modify the generated plan

The fourth and final option is to modify the generated plan itself.
This is the least preferred method because it removes a number of safeguards that OndaEDF provides as part of the planning process, but it's also the most flexible in that it enables completely hand-crafted conversion.
Here are a few examples, motivated by EDFs we have seen in the wild.

Some EEG signals have the physical units set to millivolts, but biologically generated EEG signals are generally on the order of _microvolts_.
During import, you want to correct this by adjusting the encoding settings used by Onda to store samples, by scaling the sample offset and resolution by 1000 and setting the physical units.
This can be accomplished by modifying the rows of the plan like so:

```julia
edf = EDF.File(my_edf_file_path)
plans = plan_edf_to_onda_samples(edf; label=my_labels)

function fix_millivolts(plan)
    if plan.sample_unit == "millivolt" && plan.sensor_type == "eeg"
        sample_resolution_in_unit = plan.sample_resolution_in_unit * 1000
        sample_offset_in_unit = plan.sample_offset_in_unit * 1000
        return Tables.rowmerge(plan; sample_unit="microvolt",
                               sample_resolution_in_unit,
                               sample_offset_in_unit)
    else
        return plan
    end
end

new_plan = map(fix_millivolts, Tables.rows(plans))
```

As another, similar example, sometimes EMG channels get recorded with different physical units.
In such a case, OndaEDF cannot merge these channels and will create multiple separate `Samples` objects which each have `sensor_type = "emg"`.
This can be corrected in a similar way, for exmaple by converting millivolts to microvolts (adjusting of course depending on the nature of your dataset) and re-grouping into Onda samples:

```julia
edf = EDF.File(my_edf_file_path)
plans = plan_edf_to_onda_samples(edf; label=my_labels)

function fix_emg(plan)
    if plan.sensor_type == "emg"
        if plan.sample_unit == "millivolt"
            sample_resolution_in_unit = plan.sample_resolution_in_unit * 1000
            sample_offset_in_unit = plan.sample_offset_in_unit * 1000
            plan = Tables.rowmerge(plan; sample_unit="microvolt",
                                   sample_resolution_in_unit,
                                   sample_offset_in_unit)
        end
        return plan
    else
        return plan
    end
end

new_plan = map(fix_emg, Tables.rows(plans))
# re-compute the grouping of EDF signals into Onda signals:
new_plan = plan_edf_to_onda_samples_groups(new_plan)
```

### Execute the plan

Once the plan has been reviewed and deemed satisfactory, execute the plan to generate `Onda.Samples` and an "executed plan" record.
This is accomplished with the [`edf_to_onda_samples`](@ref) function, which takes an `EDF.File` and a plan as input, and returns a `Vector{ConvertedSamples}`.
For each `sensor_label` in the plan, the corresponding [`ConvertedSamples`](@ref) captures the plan rows, the resulting `Onda.Samples`, and the `sensor_label`.

It is important to review the converted samples a final time to ensure everything was converted as expected and no unexpected errors were encountered.
First, check for any converted samples with `missing` values in the `.samples` field.
These indicated that conversion of these plan rows failed for some reason, either because the EDF signal metadata could not be matched with appropriate Onda metadata or because of a runtime error during conversion.
If any errors _were_ encountered, you may need to iterate further.

Second, check the combined plan as executed, which can be recovered via [`OndaEDF.get_plan(::Vector{ConvertedSamples})`](@ref), and may differ from the input plan.
Most notably, if any errors were encountered during execution, they will be caught and the error and stacktrace will be stored as strings in the `error` field.

### Store the output

The final step is to store both the `Onda.Samples` and the executed plan in some persistent storage.

For storing the plan, use `Legolas.write(file_path, plan, FilePlanV4SchemaVersion())` on the results of [`OndaEDF.get_plan`](@ref) (see also the documentation for [`Legolas.write`](https://beacon-biosignals.github.io/Legolas.jl/stable/#Legolas.write) and [`FilePlanV4`](@ref OndaEDF.FilePlanV4)).

For storing `Onda.Samples`, see [`Onda.store`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.store), which supports serializing LPCM-encoded samples to [any "path-like" type](https://beacon-biosignals.github.io/Onda.jl/stable/#Support-For-Generic-Path-Like-Types) (i.e., anything that provides a method for `write`).
OndaEDF.jl provides methods for `Onda.store` that accept [`ConvertedSamples`](@ref) and propagate `missing` samples.

Note that `Onda.store` requires at a minimum the file path (or "path-like" writeable), the format to use to serialize the samples (like `"lpcm"` or `"lpcm.zst"`), and the `Samples` themselves.
However, this only _serializes_ the samples to the file path.
In most cases, you will want a _signal record_ that can be stored elsewhere, which combines the path and file format to the serialized samples along with the `SamplesInfo` and other metadata required to be able to _deserialize_ and use these samples.
In this case, you should use the second `Onda.store` method which additionally requires:

- `recording::UUID` (the recording that this signal is associated with)
- `start::Period` (the start time of this signal _relative to the start of the recording_)
- `sensor_label::AbstractString` (a _unique label_, defaults to the the `sensor_label` from the `ConvertedSamples`)

While OndaEDF.jl generally creates `sensor_label`s which are valid when considering the EDF file alone, Onda requires that `sensor_label` be unique for the entire _recording_.  If you have signals from other sources that are associated with the same recording (e.g., different devices, multiple EDF files, etc.) that may have common `sensor_type`s, you must ensure that the `sensor_label`s that you store the signals with are _globally_ unique.

#### Example: storing samples and plan

```julia
edf = EDF.File(edf_path)
converted_samples = edf_to_onda_samples(edf, plans)

# generate SignalV2 rows
start_relative_to_recording = Second(0)
signals = map(converted_samples) do converted
    return Onda.store(joinpath("samples", recording, converted.sensor_label * ".lpcm"),
                      "lpcm", converted, recording, start_relative_to_recording)
end

# write combined signals table out
Legolas.write(string(recording, ".onda.signal.arrow"),
              Onda.SignalV2SchemaVersion(),
              skipmissing(signals))

# write plan table out
Legolas.write(string(recording, ".ondaedf.file-plan.arrow"),
              OndaEDF.FilePlanV4SchemaVersion(),
              OndaEDF.get_plan(converted_samples))
```

#### Example: generating unique `sensor_label`s

Consider a case with parallel recordings from a traditional EEG system (received as an EDF) and some custom EEG hardware (which emits Onda-formatted data natively).
Each device generates multichannel EEG data and uses `sensor_type="eeg"`.
We must adjust the generated sensor labels for the EDF signals before storing them so that they are unique, which we can do by prepending `"edf_"` to the default, `sensor_type`-derived labels before storing:

```julia
recording = uuid4()
prototype_signals = ingest_prototype_device_as_onda(prototype_path, recording)

edf = EDF.File(edf_path)
plans = map(plan_edf_to_onda_samples(edf)) do plan
    Legolas.record_merge(plan; recording, sensor_label="edf_" * plan.sensor_label)
end

converted_samples = edf_to_onda_samples(edf, plans)

start_relative_to_recording = Second(0)
edf_signals = map(converted_samples) do converted
    return Onda.store(joinpath("samples", recording, converted.sensor_label * ".lpcm"),
                      "lpcm", converted, recording, start_relative_to_recording)
end

# write combined signals table out
all_signals = vcat(prototype_signals, skipmissing(edf_signals))
@assert allunique(s.sensor_label for s in all_signals)
Legolas.write(string(recording, ".onda.signal.arrow"),
              Onda.SignalV2SchemaVersion(),
              all_signals)

# write plan table out
Legolas.write(string(recording, ".ondaedf.file-plan.arrow"),
              OndaEDF.FilePlanV4SchemaVersion(),
              OndaEDF.get_plan(converted_samples))
```

## Batch conversion of many EDFs

The workflow for bulk conversion of multiple EDFs is similar to the workflow for converting a single EDF.
The major difference is that the "planning" steps can be conducted in bulk, while the "execution" steps (generally) need to be conducted one at a time, either serially or distributed across multiple workers.
As discussed above, the planning stage requires only a few KB from the EDF file/signal headers, facilitating rapid plan-review-revise iteration of even fairly large collections of EDFs (10,000+).

### Planning multiple EDFs

The main factor to consider when planning conversion of a large batch of EDF files is that planning requires only the (small number) of header bytes, even for very large EDF files.
Thus, the first step is to read the file headers into memory without reading the signal data itself (which for more than a few EDF files will not usually fit into memory due to the large amount of signal data found in EDF files).

#### Reading headers from local filesystem

For EDF files stored on a normal filesystem, the `EDF.File` constructor will by default create a "header-only" `EDF.File`, so multiple files' headers can be read like

```julia
files = map(edf_paths) do path
    open(EDF.File, path, "r")
end
```

#### Reading headers from S3

!!! note
    This section may become obsolete in a future version of EDF.jl which uses the [conditional dependency](https://pkgdocs.julialang.org/v1/creating-packages/#Weak-dependencies) functionality available from Julia 1.9+ to provide tighter integration with AWSS3.jl.

Unfortunately, `open(path::S3Path)` will fetch the entire contents of the object stored at `path`, so we need to be a bit clever to read _only_ header bytes from an S3 file, especially given that the number of bytes we need to read depends on the number of signals.
The following is an example of one technique for reading EDF file and signal headers from S3:

```julia
function EDF.read_file_header(path::S3Path)
    bytes = s3_get(path.bucket, path.key; byte_range=1:256)
    buffer = IOBuffer(bytes)
    return EDF.read_file_header(buffer)
end

function EDF.File(path::S3Path)
    _, n_signals = EDF.read_file_header(path)
    bytes = s3_get(path.bucket, path.key; byte_range=1:(256 * (n_signals + 1)))
    return EDF.File(IOBuffer(bytes))
end

# use asyncmap because this is mostly bound by request roundtrip latency
files = asyncmap(EDF.File, edf_paths)
```

#### Concatenating plans into one big table

When doing bulk review of plans, it's generally helpful to have the individual files' plans concatenated into a single large table.
It's important to keep track of which plan rows corresopnd to which input file, which can be accomplished via something like this:

```julia
# create a UUID namespace to make recording ID generation idempotent
const NAMESPACE = UUID(...)
function plan_all(edf_paths, files; kwargs...)
    plans = mapreduce(vcat, edf_paths, files) do origin_uri, edf
        plan = plan_edf_to_onda_samples(edf; kwargs...)
        plan = DataFrame(plan)
        # make sure this is the same every time this function is re-run!
        recording = uuid5(NAMESPACE, string(origin_uri))
        return insertcols!(plan,
                           :origin_uri => origin_uri,
                           :recording => recording)
    end
end
```

### Review and revise the plans

This "bulk plan" table can then be reviewed in bulk, looking for patterns in which `label`s are not matched, physical units associated with each `sensor_type`, etc.
At a minimum, we find it useful to print some basic counts:

```julia
plans = plan_all(...)
# helper function to tally rows per group
tally(df, g, agg...=nrow => :count) = combine(groupby(df, g), agg...)
unmatched_labels = filter(:channel => ismissing, plans)
@info "unmatched labels:" tally(unmatched_labels, :label)

unmatched_units = filter(:sample_unit => ismissing, plans)
@info "unmatched labels:" tally(unmatched_units, :physical_dimension)

matched = subset(plans, :channel => ByRow(!ismissing), :sample_unit => ByRow(!ismissing))
@info "matched sensor types/channels:" tally(matched, [:sensor_type, :channel, :sample_unit])
```

Reviewing these summaries is a good first step when revising the plans.
The revision process is basically the same as with a single EDF: update the `labels=` and `units=` as needed to capture any un-matched EDF signals, and failing that, preprocess the headers/postprocess the plan.
Note that if it is necessary to run [`plan_edf_to_onda_samples_groups`](@ref), this must be done one file at a time, using something like this to preserve the recording-level keys created above:

```julia
new_plans = combine(groupby(plans, [:recording, :origin_uri])) do plan
    new_plan = plan_edf_to_onda_samples_groups(Tables.rows(plan))
    return DataFrame(new_plan)
end
```

### Executing bulk plans and storing generated samples

The last step, as with single EDF conversion, is to execute the plans.
Given that this requires loading signal data into memory, it's generally necessary to do this one recording at a time, either serially on a single process or using [multiprocessing](https://docs.julialang.org/en/v1/manual/distributed-computing/) to distribute work over different processes or even machines.
A complete introduction to multiprocessing in Julia is outside the scope of this guide, but we offer a few pointers in the hope that we can help avoid common pitfalls.

First, it's generally a good idea to create a function that accepts one recording's plan, EDF file path, and recording ID (or generally any additional metadata that is required to create a persistent record), which will execute the plan and persistently store the resulting samples and executed plan.
This function then may return either the generated `Onda.SignalV2` and `OndaEDF.FilePlanV2` tables for the completed recording, or pointers to where these are stored.
This way, the memory pressure involved in loading an entire EDF's signal data is confined to function scope which makes it slightly easier for Julia's garbage collector.

Second, a _separate_ function should handle coordinating these individual jobs and then collecting these results into the ultimate aggregate signal and plan tables, and then persistently storing _those_ to a final destination.
