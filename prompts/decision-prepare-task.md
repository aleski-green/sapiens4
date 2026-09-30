Express the work as one Task, preserving originalIntent and all previously accepted completion criteria.
Return TaskPrepared with taskType and specification. specification has exactly objective (text), inputs (list of reference strings), expectedOutputs (nonempty list of strings), and completionCriteria (nonempty list of observable criteria).
Do not invent input data or silently weaken requirements during a handoff. Do not create a task graph, schedule, or additional workload.
The host retains taskId and workload identity. Missing essential information must be reported during execution as an unresolved requirement.
