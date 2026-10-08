-- System Pulsation: the global Corpora execution clock and chat Agencies.
-- Revised 2026-10-08. Python implementation: host/pulsation.py and host/agency.py.
-- This supersedes the earlier Pulse-as-workload-classifier interpretation.
module SystemPulsation where

type SapiId = String
type MessageId = String
type AgencyRunId = String
type Text = String

-- 1. Clock: identity, frequencies, and batching policy --------------------
newtype Pulse = Pulse String deriving (Eq, Show)
data PulsationFrequency = Bpm120 | Bpm60 | Bph60 deriving (Eq, Show)
data PulseId = PulseId Pulse PulsationFrequency Integer deriving (Eq, Show)

intervalSeconds :: PulsationFrequency -> Double
intervalSeconds Bpm120 = 0.5
intervalSeconds Bpm60  = 1
intervalSeconds Bph60  = 60

data Pulsation a = Pulsation
  { frequency   :: PulsationFrequency
  , pulseNum    :: Integer
  , callsBuffer :: [AgencyBatch a]
  }

data CallDecision = Call | NoCall deriving (Eq, Show)
newtype AgencyBatch a = AgencyBatch [a] deriving (Eq, Show)
data BatchPolicy a = BatchPolicy
  { pulsation :: PulsationFrequency
  , every     :: Integer
  , decide    :: AgencyBatch a -> CallDecision
  }

chatBatchPolicy :: BatchPolicy a
chatBatchPolicy = BatchPolicy
  { pulsation = Bpm60
  , every = 2
  , decide = \(AgencyBatch inputs) -> if null inputs then NoCall else Call
  }

nextBatchPulseNum :: BatchPolicy a -> Integer -> Integer
nextBatchPulseNum policy previous = previous + every policy

-- NoCall suppresses call actions, never the clock or next batch number.
-- A free slot AND nonempty input are required even if a custom lambda says Call.
shouldCall :: BatchPolicy a -> Integer -> Bool -> AgencyBatch a -> Bool
shouldCall policy number freeSlot batch@(AgencyBatch inputs) =
  number `mod` every policy == 0 && freeSlot && not (null inputs)
    && decide policy batch == Call

-- One global Pulse owns all three concurrent frequency streams. Pulse numbers
-- are monotonic within a frequency, persist across restarts, and advance during
-- empty or capacity-blocked ticks. Calls receive the actual dispatch PulseId.
-- The Python clock coalesces missed ticks without replaying a burst of calls.
-- Stop disables dispatch and requests cancellation of running model processes;
-- buffered inputs and completed outputs persist. External effects are not undone.

-- 2. Agency: ownership, slots, and run context ---------------------------
data AgencyKind = ChatInput | ChatOutput deriving (Eq, Show)
data AgencySlot = AgencySlot
  { owner     :: SapiId
  , kind      :: AgencyKind
  , slotNum   :: Int
  , activeRun :: Maybe AgencyRunId
  } deriving (Eq, Show)

chatSlots :: SapiId -> [AgencySlot]
chatSlots sapi = [AgencySlot sapi k n Nothing | k <- [ChatInput, ChatOutput], n <- [1, 2]]

data Message = Message
  { messageId            :: MessageId
  , content              :: Text
  , underPrevAgencyReview :: Bool
  } deriving (Eq, Show)

newtype StaticContext = CorporaStatePrompt Text deriving (Eq, Show)
data InstantContext = InstantContext
  { last20Messages :: [Message]
  , fullMemo       :: Text
  } deriving (Eq, Show)

data AgencyRunInput = AgencyRunInput
  { staticContext  :: StaticContext
  , instantContext :: InstantContext
  , inputs         :: AgencyBatch Message
  } deriving (Eq, Show)

-- Static context describes the Sapi, Groups, Chief, and workspace. Use whatever
-- is persisted; refreshing state/snapshots belongs to other asynchronous kinds.
-- Last 20 messages include the current inputs; there is NO exclusion.
-- Earlier unfinished batches are marked underPrevAgencyReview.
-- Full Memo is supplied for now. TODO: context-specific SubMemo.
-- One run per slot. Two input slots may run concurrently for the same Sapi.
-- The shared computer still has one owner, identified by AgencyRun, not Sapi.

-- 3. Chat: accumulating input, output FIFO, and observable dispatches ------
data ChatBuffers = ChatBuffers
  { pendingInput  :: AgencyBatch Message
  , pendingOutput :: [AgencyBatch Message]
  } deriving (Eq, Show)

-- Input: messages accumulate until an eligible pulse has a free slot. The
-- complete pending batch is claimed atomically by one chatInput run. Both slots
-- busy means continued accumulation, not a queue of sealed interval batches.
-- Finishing input durably appends its result to the output FIFO, freeing its slot.
-- Output: deterministic rendering, no additional LLM. Two slots can publish two
-- FIFO results at the same eligible pulse, preserving two separate chat bubbles.
-- FIFO means output-arrival order; it does not wait for earlier input batches.
-- Each direction has its own BatchPolicy, initially the same chatBatchPolicy.
-- Crashed started runs become interrupted and require explicit retry. A saved
-- output is published once after restart; it does not rerun its input Agency.

data PulseCall = PulseCall
  { dispatchedPulse :: Pulse
  , dispatchedAt    :: PulseId
  , agencyKind      :: AgencyKind
  , slot            :: Int
  , timestamp       :: Text
  } deriving (Eq, Show)

-- Updates shows ONLY call-producing pulses: frequency, pulse number, Pulse,
-- PulseId, AgencyKind, slot and human-readable timestamp. No input/output body,
-- empty ticks, or NoCall decisions. Sapi ownership scopes the selected UI view.
-- Existing Group/handoff execution is admitted by Pulse too; its older internal
-- execution model remains separate from the two-slot personal-chat model.
