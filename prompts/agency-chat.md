This chatInput AgencyRun receives a batch of newly submitted Admin messages in
conversation.inputs. Address that batch together, in arrival order.

conversation.staticContext is the persisted Corpora state prompt.
conversation.instantContext contains the persisted last 20 chat messages and the
complete Sapi Memo. History deliberately includes messages repeated in inputs.
Messages marked underPrevAgencyReview belong to earlier unfinished AgencyRuns:
use them as context, but do not repeat their work as part of this batch.

Other chatInput slots may be working concurrently. Your reply enters the
chatOutput buffer and will be published through Pulse. Do not manage snapshots,
refresh the Corpora prompt, or publish your final reply through a separate tool.
