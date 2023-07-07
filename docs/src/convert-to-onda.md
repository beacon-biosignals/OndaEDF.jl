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

