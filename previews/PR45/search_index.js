var documenterSearchIndex = {"docs":
[{"location":"#API-Documentation","page":"API Documentation","title":"API Documentation","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"CurrentModule = OndaEDF","category":"page"},{"location":"#Import-EDF-to-Onda","page":"API Documentation","title":"Import EDF to Onda","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"OndaEDF.jl prefers \"self-service\" import over \"automagic\", and provides functionality to extract Onda.Samples and Onda.Annotations from an EDF.File.  These can be written to disk (with Onda.store / Onda.write_annotations) or manipulated in memory as desired.","category":"page"},{"location":"","page":"API Documentation","title":"API Documentation","text":"edf_to_onda_samples\nedf_to_onda_annotations","category":"page"},{"location":"#OndaEDF.edf_to_onda_samples","page":"API Documentation","title":"OndaEDF.edf_to_onda_samples","text":"edf_to_onda_samples(edf::EDF.File; kwargs...)\n\nRead signals from an EDF.File into a vector of Onda.Samples.  This is a convenience function that first formulates an import plan via plan, and then immediately executes this plan with execute_plan.  The vector of Onda.Samples and the executed plan are returned\n\nThe samples and executed plan are returned; it is strongly advised that you review the plan for un-extracted signals (where :kind or :channel is missing) and errors (non-nothing values in :error).\n\nCollections of EDF.Signals are mapped as channels to Onda.Samples via plan.  The caller of this function can control the plan via the labels, units, and preprocess_labels keyword arguments, all of which are forwarded to plan.\n\nEDF.Signal labels that are converted into Onda channel names undergo the following transformations:\n\nthe label is whitespace-stripped, parens-stripped, and lowercased\ntrailing generic EDF references (e.g. \"ref\", \"ref2\", etc.) are dropped\nany instance of + is replaced with _plus_ and / with _over_\nall component names are converted to their \"canonical names\" when possible (e.g. \"m1\" in an EEG-matched channel name will be converted to \"a1\").\n\nSee the OndaEDF README for additional details regarding EDF formatting expectations.\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.edf_to_onda_annotations","page":"API Documentation","title":"OndaEDF.edf_to_onda_annotations","text":"edf_to_onda_annotations(edf::EDF.File, uuid::UUID)\n\nExtract EDF+ annotations from an EDF.File for recording with ID uuid and return them as a vector of Onda.Annotations.  Each returned annotation has a  value field that contains the string value of the corresponding EDF+ annotation.\n\nIf no EDF+ annotations are found in edf, then an empty Vector{Annotation} is returned.\n\n\n\n\n\n","category":"function"},{"location":"#Import-utilities","page":"API Documentation","title":"Import utilities","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"plan\nexecute_plan\nmatch_edf_label\nmerge_samples_info","category":"page"},{"location":"#OndaEDF.plan","page":"API Documentation","title":"OndaEDF.plan","text":"plan(header, seconds_per_record; labels=STANDARD_LABELS,\n     units=STANDARD_UNITS, preprocess_labels=(l,t) -> l)\nplan(signal::EDF.Signal, args...; kwargs...) = plan(signal.header, args...; kwargs...)\n\nFormulate a plan for converting an EDF signal into Onda format.  This returns a Tables.jl row with all the columns from the signal header, plus additional columns for the Onda.SamplesInfo for this signal, and the seconds_per_record that is passed in here.\n\nIf no labels match, then the channel and kind columns are missing; the behavior of other SamplesInfo columns is undefined; they are currently set to missing but that may change in future versions.\n\nAny errors that are thrown in the process will be stored as SampleInfoErrors in the error column.\n\nMatching EDF label to Onda labels\n\nThe labels keyword argument determines how Onda channel and signal kind are extracted from the EDF label.\n\nLabels are specified as an iterable of signal_names => channel_names pairs. signal_names should be an iterable of signal names, the first of which is the canonical name used as the Onda kind.  Each element of channel_names gives the specification for one channel, which can either be a string, or a canonical_name => alternates pair.  Occurences of alternates will be replaces with canonical_name in the generated channel label.\n\nMatching is determined solely by the channel names.  When matching, the signal names are only used to remove signal names occuring as prefixes (e.g., \"[ECG] AVL\") before matching channel names.  See match_edf_label for details, and see OndaEDF.STANDARD_LABELS for the default labels.\n\nAs an example, here is (a subset of) the default labels for ECG signals:\n\n[\"ecg\", \"ekg\"] => [\"i\" => [\"1\"], \"ii\" => [\"2\"], \"iii\" => [\"3\"],\n                   \"avl\"=> [\"ecgl\", \"ekgl\", \"ecg\", \"ekg\", \"l\"], \n                   \"avr\"=> [\"ekgr\", \"ecgr\", \"r\"], ...]\n\nMatching is done in the order that labels iterates pairs, and will stop at the first match, with no warning if signals are ambiguous (although this may change in a future version)\n\n\n\n\n\nplan(edf::EDF.File;\n     labels=STANDARD_LABELS,\n     units=STANDARD_UNITS,\n     preprocess_labels=(l,t) -> l,\n     onda_signal_groups=grouper((:kind, :sample_unit, :sample_rate)))\n\nFormulate a plan for converting an EDF.File to Onda Samples.  This applies plan to each individual signal contained in the file, storing edf_signal_idx as an additional column.  The resulting rows are then grouped according to onda_signal_grouper (by default, the :kind, :sample_unit, and :sample_rate columns), and the group index is added as an additional column in onda_signal_idx.\n\nThe resulting plan is returned as a table.  No signal data is actually read from the EDF file; to execute this plan and generate Onda.Samples, use execute_plan\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.execute_plan","page":"API Documentation","title":"OndaEDF.execute_plan","text":"execute_plan(plan_table, edf::EDF.File;\n             samples_groups=grouper((:onda_signal_idx, )))\n\nExecute an EDF import plan specified in plan_table (e.g., as generated by plan), returning an iterable of the generated Onda.Samples and the plan as actually executed.\n\nThe input plan is transformed by using merge_samples_info to combine rows with the same :onda_signal_idx (or output of sample_groups) into a common Onda.SamplesInfo.  Then onda_samples_from_edf_signals is used to combine the EDF signals data into a single Onda.Samples per group.\n\nThe label of the original EDF.Signals are preserved in the :edf_channels field of the resulting SamplesInfos for each Samples generated.\n\nAny errors that occur are inserted into the :error column for the corresponding rows from the plan.\n\nSamples are returned in the order of :onda_signal_idx (or otherwise the output of the samples_groups function).  Signals that could not be matched or otherwise caused an error during execution are not returned.\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.match_edf_label","page":"API Documentation","title":"OndaEDF.match_edf_label","text":"match_edf_label(label, signal_names, channel_name, canonical_names)\n\nReturn a normalized label matched from and EDF label.  The purpose of this function is to remove signal names from the label, and to canonicalize the channel name(s) that remain.  So something like \"[eCG] avl-REF\" will be transformed to \"avl\" (given signal_names=[\"ecg\"], and channel_name=\"avl\")\n\nThis returns nothing if channel_name does not match after normalization\n\nCanonicalization\n\nensures the given label is whitespace-stripped, lowercase, and parens-free\nstrips trailing generic EDF references (e.g. \"ref\", \"ref2\", etc.)\nreplaces all references with the appropriate name as specified by canonical_names\nreplaces + with _plus_ and / with _over_\nreturns the initial reference name (w/o prefix sign, if present) and the entire label; the initial reference name should match the canonical channel name, otherwise the channel extraction will be rejected.\n\nExamples\n\nmatch_edf_label(\"[ekG]  avl-REF\", [\"ecg\", \"ekg\"], \"avl\", []) == \"avl\"\nmatch_edf_label(\"ECG 2\", [\"ecg\", \"ekg\"], \"ii\", [\"ii\" => [\"2\", \"two\", \"ecg2\"]]) == \"ii\"\n\nSee the tests for more examples\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.merge_samples_info","page":"API Documentation","title":"OndaEDF.merge_samples_info","text":"merge_samples_info(plan_rows)\n\nCreate a single, merged SamplesInfo from plan rows, such as generated by plan.  Encodings are promoted with promote_encodings.\n\nThe input rows must have the same values for :kind, :sample_unit, and :sample_rate; otherwise an ArgumentError is thrown.\n\nIf any of these values is missing, or any row's :channel value is missing, this returns missing to indicate it is not possible to determine a shared SamplesInfo.\n\nThe original EDF labels are included in the output in the :edf_channels column.\n\n\n\n\n\n","category":"function"},{"location":"#Full-service-import","page":"API Documentation","title":"Full-service import","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"For a more \"full-service\" experience, OndaEDF.jl also provides functionality to extract Onda.Samples and Onda.Annotations and then write them to disk:","category":"page"},{"location":"","page":"API Documentation","title":"API Documentation","text":"store_edf_as_onda","category":"page"},{"location":"#OndaEDF.store_edf_as_onda","page":"API Documentation","title":"OndaEDF.store_edf_as_onda","text":"store_edf_as_onda(edf::EDF.File, onda_dir, recording_uuid::UUID=uuid4();\n                  custom_extractors=STANDARD_EXTRACTORS, import_annotations::Bool=true,\n                  postprocess_samples=identity,\n                  signals_prefix=\"edf\", annotations_prefix=signals_prefix)\n\nConvert an EDF.File to Onda.Samples and Onda.Annotations, store the samples in $path/samples/, and write the Onda signals and annotations tables to $path/$(signals_prefix).onda.signals.arrow and $path/$(annotations_prefix).onda.annotations.arrow.  The default prefix is \"edf\", and if a prefix is provided for signals but not annotations both will use the signals prefix.  The prefixes cannot reference (sub)directories.\n\nReturns (; recording_uuid, signals, annotations, signals_path, annotations_path, plan).\n\nThis is a convenience function that first formulates an import plan via plan, and then immediately executes this plan with execute_plan.\n\nThe samples and executed plan are returned; it is strongly advised that you review the plan for un-extracted signals (where :kind or :channel is missing) and errors (non-nothing values in :error).\n\nGroups of EDF.Signals are mapped as channels to Onda.Samples via plan.  The caller of this function can control the plan via the labels, units, and preprocess_labels keyword arguments, all of which are forwarded to plan.\n\nEDF.Signal labels that are converted into Onda channel names undergo the following transformations:\n\nthe label is whitespace-stripped, parens-stripped, and lowercased\ntrailing generic EDF references (e.g. \"ref\", \"ref2\", etc.) are dropped\nany instance of + is replaced with _plus_ and / with _over_\nall component names are converted to their \"canonical names\" when possible (e.g. \"m1\" in an EEG-matched channel name will be converted to \"a1\").\n\nSee the OndaEDF README for additional details regarding EDF formatting expectations.\n\n\n\n\n\n","category":"function"},{"location":"#Export-EDF-from-Onda","page":"API Documentation","title":"Export EDF from Onda","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"onda_to_edf","category":"page"},{"location":"#OndaEDF.onda_to_edf","page":"API Documentation","title":"OndaEDF.onda_to_edf","text":"onda_to_edf(signals, annotations=[]; kwargs...)\n\nReturn an EDF.File containing signal data converted from the Onda signals table and (optionally) annotations from an annotations table.\n\nFollowing the Onda v0.5 format, both signals and annotations can be any Tables.jl-compatible table (DataFrame, Arrow.Table, NamedTuple of vectors, vector of NamedTuples) which follow the signal and annotation schemas (respectively).\n\nEach EDF.Signal in the returned EDF.File corresponds to a channel of an Onda.Signal.\n\nThe ordering of EDF.Signals in the output will match the order of the rows of the signals table (and within each channel grouping, the order of the signal's channels).\n\n\n\n\n\n","category":"function"}]
}
