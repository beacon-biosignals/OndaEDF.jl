# An Opinionated Guide to Converting EDFs to Onda

## Basic workflow

At a high level, the basic workflow for EDF-to-Onda conversion is iterative:
1. Formulate a "plan" which specifies how to convert the metadata associated with each `EDF.Signal` into Onda metadata (channel names, quantization/encoding parameters, etc.)
2. Review the plan, making sure that all necessary `EDF.Signal`s will be extracted, and that the quantization, sample rate, physical units, etc. are reasonable.
3. Revise the plan as needed, repeating steps 1-2 until you're happy.
4. Execute the plan, loading all EDF signal data if necessary and converting into `Onda.Samples`

In the following sections, we expand on the philosophy behind OndaEDF's EDF-to-Onda design and present some detailed, opinionated workflows for converting a single EDF and multiple EDFs.

## Philosophy

The motivation for separating the planning and execution is twofold.

First, making the plan a separate intermediate output means that not only can it be reviewed during conversion but can be persisted as a record of how any EDF-derived Onda signals were converted.
This kind of provenance information is very useful when investigating issues with a dataset that may crop up long after the initial conversion.

Second, planning only requires that the _headers_ of the `EDF.Signal`s be read into memory, thereby separating the iterative part of the conversion process from the expensive, one-time step which requires _all_ the signal data be read into memory.
This enables workflows that would be impossible otherwise, like planning bulk conversion of thousands of EDFs at once.
When dealing with large, messy datasets, we have found that "long-tail" metadata issues are inevitable and are better dealt with in bulk, and the plan-then-execute workflow enables users to deal with these issues all at once, save out the plan, and then distribute the actual conversion work to as many workers as necessary to execute it in a reasonable timeframe.

## Converting a single EDF to Onda

The following steps assume you have read an EDF file into memory with `EDF.read` or otherwise created an `EDF.File`.
After the detailed workflow for converting a single EDF file to Onda format, we'll discuss how to handle batches of EDF files.

### Generate a plan

This is straightforward, using [`plan_edf_to_onda_samples`](@ref).
As outlined in the documentation for [`plan_edf_to_onda_samples`](@ref), a "plan" is a table with one row per `EDF.Signal`, which contains all the fields from the signal's header as well as the fields of the `Onda.SamplesInfoV2` that will be generated when the plan is executed (with the caveat that the `channels` field is called `channel` to indicate that it corresponds to a single channel in the output).

### Review the plan.

Check for EDF signals whose `label` or `physical_dimension` could not be matched using the standard OndaEDF labels and units, as indicated by `missing` values in the `channel`/`sensor_type` (for un-matched `label`) or `sample_unit` (for un-matched `physical_dimension`).
It's also a good idea at this point to review the other EDF signal header fields, and how they will be converted to Onda (especially the sample unit, resolution and offset, which correspond to the physical/digital minimum/maximum from the EDF signal header.
However, it's harder to fix issues with these fields, but it's still better to detect and document any issues with the underlying EDF data at this stage to prevent nasty surprises down the road.

### Revise the plan

If there are EDF signals with un-matched `label` or `physical_dimension`, you have a few options.
We recommend you consider them in roughly this order.

#### Skip them

The first option to consider is to simply ignore these signals; not all signals are necessarily required for downstream use, and converting each and every signal in an EDF may be more work than is justified!

#### Custom labels and units

The second option you have is to provide custom `labels=` and `units=` keyword arguments to [`plan_edf_to_onda_samples`](@ref).
For unambiguous, [spec-compliant](https://www.edfplus.info/specs/edftexts.html#label_physidim) `label`s and `physical_dimension`s, it's generally possible to create custom `label=` or `unit=` specifications to match them.

!!! note
    Custom labels should be specified as _lowercase_, without reference, and without the sensor type prefix.
    So to match a label like `"EEG R1-Ref"`, use a label like `"eeg" => ["r1"]`, and not `"EEG" => ["R1"]` or `"eeg" => ["r1-ref"]`.
    See the documentation for [`plan_edf_to_onda_samples`](@ref) for more details, and the internal [`OndaEDF.match_edf_label`](@ref) for low-level details of how labels are matched.

#### Preprocessing signal headers

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

#### Modification of the generated plan

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
This is accomplished with the [`edf_to_onda_samples`](@ref) function, which takes an `EDF.File` and a plan as input, and returns a vector of `Onda.Samples` and the plan as executed.
The executed plan may differ from the input plan.
Most notably, if any errors were encountered during execution, they will be caught and the error and stacktrace will be stored as strings in the `error` field.
It is important to review the executed plan a final time to ensure everything was converted as expected and no unexpected errors were encountered.

### Store the output

The final step is to store both the `Onda.Samples` and the executed plan in some persistent storage.
For storing `Onda.Samples`, see [`Onda.store`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.store), which supports serializing LPCM-encoded samples to [any "path-like" type](https://beacon-biosignals.github.io/Onda.jl/stable/#Support-For-Generic-Path-Like-Types) (i.e., anything that provides a method for `write`).
For storing the plan, use `Legolas.write(file_path, plan, FilePlanV2SchemaVersion())` (see the documentation for [`Legolas.write`](https://beacon-biosignals.github.io/Legolas.jl/stable/#Legolas.write) and [`FilePlanV2`](@ref).

## Batch conversion of many EDFs

The workflow for bulk conversion of multiple EDFs is similar to the workflow for converting a single EDF.
The major difference is that the "planning" steps can be conducted in bulk, while the "execution" steps (generally) need to be conducted one at a time, either serially or distributed across multiple workers.
As discussed above, the planning stage requires only a few KB from the EDF file/signal headers, facilitating rapid plan-review-revise iteration of even fairly large collections of EDFs (10,000+).

### Reading EDF headers
