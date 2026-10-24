module Sapiens.Tasks (main) where

import Prelude
import Control.Alt ((<|>))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn1, EffectFn2, mkEffectFn1, mkEffectFn2, mkEffectFn3, runEffectFn1, runEffectFn2)
import Foreign.Object as Object
import Sapiens.Async (Promise, fromPromise)
import Sapiens.Browser as B
import Sapiens.View as V

foreign import stringify :: forall a. a -> String
foreign import dateParse :: String -> Number

type Task =
  { id :: String, state :: String, title :: String, body :: String, owner :: String, sender :: String
  , meta :: Nullable String, result :: Nullable String, error :: Nullable String, taskType :: Nullable String
  , editRoutine :: Nullable String, routineAction :: Nullable String, reference :: Nullable String, runCount :: Int }
type Turn = { id :: String, created :: String, status :: String }
type Workload =
  { id :: String, callId :: String, owner :: String, state :: String, output :: Nullable String, error :: Nullable String
  , participants :: Array String, origin :: {agent :: String, call :: String}, taskId :: String }
type Message =
  { role :: String, author :: String, text :: String, time :: String, timestamp :: Number
  , delegation :: Workload, requestTurn :: Nullable Turn }
type Snapshot = { workloads :: Nullable (Array Workload), turns :: Array Turn }
type Prompt = {node :: String, content :: String, path :: String}
type Context =
  { selected :: Effect String, panel :: Effect String, workView :: Effect String, period :: Effect String
  , workloads :: Effect (Array Workload), agentName :: EffectFn1 String String
  , formatText :: EffectFn1 String String, displayTime :: EffectFn1 String String
  , toast :: EffectFn1 String Unit, fetchTasks :: EffectFn1 String (Promise {tasks :: Array Task})
  , appendMessage :: EffectFn2 String Message Unit, ensureMessages :: EffectFn1 String Unit
  , openChat :: EffectFn1 String Unit, clarify :: EffectFn1 Workload Unit
  , prompts :: Effect (Promise {prompts :: Array Prompt})
  , savePrompt :: EffectFn2 String String (Promise {path :: String})
  , modal :: EffectFn2 String String Unit }
type Cached = {revision :: String, rows :: Maybe (Array Task), pending :: Boolean, error :: Maybe String, serial :: Int}

foreign import nullTurn :: Nullable Turn
foreign import nullableTurn :: Turn -> Nullable Turn

past :: String -> Boolean
past state = Array.elem state ["Completed", "Unresolved", "Failed", "Interrupted", "Cancelled"]

nonempty :: Nullable String -> Maybe String
nonempty value = case toMaybe value of
  Just "" -> Nothing
  other -> other

element :: String -> String -> Maybe String -> Effect B.Element
element tag className content = V.build $ V.el tag [V.klass className] $
  case content of
    Nothing -> []
    Just text -> [V.text_ text]

label :: String -> String -> String -> Effect B.Element
label tag className content = element tag className $ Just content

button :: String -> String -> Effect B.Element
button className content = do
  node <- label "button" className content
  B.setProperty "type" "button" node
  pure node

await :: forall a. Effect (Promise a) -> Aff a
await action = liftEffect action >>= fromPromise

mount :: Context -> Effect
  { taskRow :: EffectFn2 Task String B.Element, renderTasks :: EffectFn1 B.Element Unit
  , delegationMessages :: EffectFn1 Snapshot Unit, taskCallControls :: EffectFn1 B.Element Unit
  , editDecisionPrompts :: Effect Unit }
mount context = do
  openTasks <- Ref.new ([] :: Array String)
  documents <- Ref.new (Object.empty :: Object.Object (Ref.Ref Cached))
  serial <- Ref.new 0
  let
    taskRow task sapi = do
      opened <- Ref.read openTasks
      owner <- runEffectFn1 context.agentName task.owner
      sender <- runEffectFn1 context.agentName task.sender
      resultHTML <- case nonempty task.result of
        Nothing -> pure ""
        Just result -> runEffectFn1 context.formatText result
      let
        key = sapi <> ":" <> task.id
        tone | task.state == "Completed" = "complete"
             | Array.elem task.state ["Failed", "Interrupted", "Unresolved", "WaitingForAdmin"] = "attention"
             | Array.elem task.state ["Running", "Queued"] = "active"
             | otherwise = "neutral"
        routine = isJust $ nonempty task.editRoutine
        route = if task.sender == task.owner then owner else sender <> " → " <> owner
        optional value draw = maybe [] (pure <<< draw) (nonempty value)
        action label attrs = V.el "button" ([V.klass "task-copy", V.attr "type" "button", V.on "click" B.preventDefault] <> attrs) [V.text_ label]
        routineButtons = case nonempty task.editRoutine of
          Nothing -> []
          Just id ->
            let paused = toMaybe task.routineAction == Just "resume"
                title = if paused then "Resume routine" else "Pause routine"
            in [ action "Run" [V.attr "data-run-routine" id, V.attr "aria-label" "Run routine"]
               , action "Edit" [V.attr "data-edit-routine" id]
               , V.el "button" [V.klass "task-copy task-routine-action", V.attr "type" "button"
                   , V.attr (if paused then "data-resume-routine" else "data-pause-routine") id
                   , V.attr "title" title, V.attr "aria-label" title, V.on "click" B.preventDefault]
                   [ V.html $ "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" aria-hidden=\"true\">" <>
                       (if paused then "<path d=\"M5 3l7 5-7 5z\"/>" else "<path d=\"M5 3v10M11 3v10\"/>") <> "</svg>" ]
               ]
        copyBody _ = launchAff_ do
          outcome <- try $ await $ B.writeClipboard task.body
          liftEffect $ runEffectFn1 context.toast $ case outcome of
            Right _ -> if routine then "Execution prompt copied." else "Task YAML copied."
            Left _ -> "Could not copy. You can select the task body to copy it."
        toggle event = do
          row <- B.target event
          connected <- B.property "isConnected" row
          when connected do
            expanded <- B.property "open" row
            Ref.modify_ (\previous -> (if expanded then [key] else []) <> Array.filter (_ /= key) previous) openTasks
      V.build $ V.el "details"
        ([ V.klass $ "task-row" <> if isJust (nonempty task.reference) then " task-routine" else ""
         , V.on "toggle" toggle ] <> if Array.elem key opened then [V.attr "open" ""] else [])
        [ V.el "summary" [V.klass "task-summary"] $
            [ V.el "span" [V.klass $ "task-mark " <> tone, V.attr "aria-hidden" "true"]
                [V.text_ $ if task.state == "Completed" then "✓" else if tone == "attention" then "!" else "·"]
            , V.el "span" [V.klass "task-row-copy"]
                [ V.el "span" [V.klass "task-title", V.attr "title" task.title] [V.text_ task.title]
                , V.el "span" [V.klass "task-meta"]
                    [ V.text "span" ("task-state " <> tone) (if task.state == "WaitingForAdmin" then "Needs input" else task.state)
                    , V.text "span" "task-assignee" $ fromMaybe route $ nonempty task.meta ] ]
            ] <> routineButtons <> optional task.reference (\reference ->
              V.el "span" [V.klass "task-reference", V.attr "title" "Scheduled tasks queued in this allowance; pauses automatically at 1000."]
                [V.text "code" "" reference, V.text "span" "" $ show task.runCount <> "/1000"])
              <> [V.el "span" [V.klass "task-chevron", V.attr "aria-hidden" "true"] [V.text_ "›"]]
        , V.el "div" [V.klass "task-content"] $
            [ V.el "div" [V.klass "task-body-heading"]
                [ V.text "span" "" $ if routine then "Execution prompt" else "Task body"
                , V.text "span" "task-format" $ if routine then "" else "YAML"
                , V.el "button" [V.klass "task-copy", V.attr "type" "button"
                    , V.attr "aria-label" $ if routine then "Copy execution prompt" else "Copy task YAML"
                    , V.on "click" copyBody ] [V.text_ "Copy"] ]
            , V.el "pre" [V.klass "task-body-yaml", V.attr "aria-label" $ if routine then "Execution prompt" else "Task body YAML"] [V.text_ task.body]
            ] <> (if resultHTML == "" then [] else
              [V.text "h3" "task-result-heading" "Result", V.el "div" [V.klass "task-result"] [V.html resultHTML]])
              <> optional task.error (V.text "p" "task-error")
        ]

    drawTasks host id cached = do
      viewName <- context.workView
      period <- context.period
      let automated = viewName == "tasks-automated"
      -- Keep DOM identity stable across unchanged polling, preserving focus and expansion.
      let key = stringify {id, revision:cached.revision, period, automated, pending:cached.pending, error:cached.error}
      first <- B.property "firstElementChild" host
      previous <- case toMaybe first of
        Nothing -> pure Nothing
        Just node -> toMaybe <$> B.property "taskViewKey" node
      unless (previous == Just key) do
        view <- element "section" "task-browser" Nothing
        B.setProperty "taskViewKey" key view
        list <- element "div" "task-list" Nothing
        B.setProperty "id" "task-list" list
        B.setAttribute "aria-label" (if period == "past" then "Executed tasks" else "Planned tasks") list
        B.setAttribute "aria-busy" (show cached.pending) list
        let visible = Array.filter (\task -> past task.state == (period == "past") &&
              (not automated || toMaybe task.taskType == Just "automated")) $ fromMaybe [] cached.rows
        case cached.error of
          Just _ -> do
            error <- element "div" "task-empty" Nothing
            message <- label "p" "" "Could not load tasks."
            retry <- button "task-copy" "Try again"
            B.listen "click" false (\_ -> do
              Ref.modify_ (Object.delete id) documents
              renderTasks host
              ) retry
            B.appendChildren [message, retry] error
            B.appendChildren [error] list
          Nothing -> case cached.rows of
            Nothing -> do
              loading <- label "p" "task-empty" "Loading tasks…"
              B.appendChildren [loading] list
            Just _ | Array.null visible -> do
              empty <- element "div" "task-empty" Nothing
              message <- label "p" "" $ if period == "past" then "No executed tasks" else "No planned tasks"
              detail <- label "small" "" $ if period == "past" then "Completed and stopped tasks will appear here." else "Queued, running and waiting tasks will appear here."
              B.appendChildren [message, detail] empty
              B.appendChildren [empty] list
            Just _ -> for_ visible \task -> do
              node <- taskRow task id
              B.appendChildren [node] list
        B.appendChildren [list] view
        V.disposeContents host
        B.replaceChildren [view] host

    renderTasks host = do
      id <- context.selected
      workloads <- context.workloads
      let revision = stringify $ Array.filter (\work -> Array.elem id work.participants) workloads
      cache <- Ref.read documents
      previous <- case Object.lookup id cache of
        Nothing -> pure Nothing
        Just reference -> Just <$> Ref.read reference
      case previous of
        Just cached | cached.revision == revision -> drawTasks host id cached
        _ -> do
          next <- Ref.modify (_ + 1) serial
          let cached = {revision, rows:previous >>= _.rows, pending:true, error:Nothing, serial:next}
          reference <- Ref.new cached
          Ref.modify_ (Object.insert id reference) documents
          drawTasks host id cached
          launchAff_ do
            outcome <- try $ await $ runEffectFn1 context.fetchTasks ("/api/agents/" <> B.encodeURIComponent id <> "/tasks?format=json")
            liftEffect do
              let complete = case outcome of
                    Right response -> cached {rows = Just response.tasks, pending = false}
                    Left error -> cached {error = Just $ message error, pending = false}
              Ref.write complete reference
              latest <- Ref.read documents
              current <- context.selected
              panel <- context.panel
              connected <- B.property "isConnected" host
              for_ (Object.lookup id latest) \active -> do
                observed <- Ref.read active
                when (observed.serial == next && current == id && Array.elem panel ["tasks", "work"] && connected) $
                  drawTasks host id complete

    delegationMessages snapshot = for_ (fromMaybe [] $ toMaybe snapshot.workloads) \work -> do
      current <- context.selected
      when (work.origin.agent /= current) $ runEffectFn1 context.ensureMessages work.origin.agent
      when (work.callId /= work.origin.call) do
        let call = Array.find (\turn -> turn.id == work.callId) snapshot.turns
        owner <- runEffectFn1 context.agentName work.owner
        time <- case call of
          Just turn -> runEffectFn1 context.displayTime turn.created
          Nothing -> pure ""
        let requestTurn = case call of
              Just turn | not $ Array.elem turn.status ["done", "warning"] -> nullableTurn turn
              _ -> nullTurn
        runEffectFn2 context.appendMessage work.origin.agent
          {role:"assistant", author:work.owner, text:fromMaybe ("Delegated to " <> owner <> " · " <> work.state) (nonempty work.output <|> nonempty work.error)
          , time, timestamp:maybeTimestamp call, delegation:work, requestTurn}

    taskCallControls host = do
      workloads <- context.workloads
      selected <- context.selected
      for_ workloads \work -> when (work.state == "WaitingForAdmin" && Array.elem selected [work.owner, work.origin.agent]) do
        control <- button "button" "Answer Chief"
        B.setAttribute "data-chat-key" ("clarify:" <> work.id <> ":" <> work.owner <> ":" <> work.taskId) control
        B.listen "click" false (\_ -> do
          runEffectFn1 context.openChat work.owner
          runEffectFn1 context.clarify work
          input <- B.query "#message-input" B.document
          for_ (toMaybe input) \inputElement -> do
            B.setProperty "placeholder" ("Clarify " <> work.taskId <> " for Chief…") inputElement
            B.focus inputElement
          ) control
        B.appendChildren [control] host

    editDecisionPrompts = launchAff_ do
      outcome <- try do
        response <- await context.prompts
        liftEffect do
          prompts <- Ref.new response.prompts
          runEffectFn2 context.modal "Decision prompts" "<form id=\"decision-prompt-form\" class=\"form-stack\"><label>Node<select name=\"node\"></select></label><small class=\"prompt-path\"></small><label>Prompt<textarea name=\"content\" rows=\"16\" maxlength=\"20000\" required></textarea></label><p>Changes apply to subsequent decisions. Saved decision records keep their original prompt.</p><button class=\"button\" type=\"submit\">Save prompt</button></form>"
          form <- requireElement "#decision-prompt-form" B.document
          node <- requireElement "[name=node]" form
          content <- requireElement "[name=content]" form
          path <- requireElement ".prompt-path" form
          submit <- requireElement "button" form
          for_ response.prompts \prompt -> do
            option <- label "option" "" prompt.node
            B.setProperty "value" prompt.node option
            B.appendChildren [option] node
          let showPrompt = do
                id <- B.property "value" node
                rows <- Ref.read prompts
                for_ (Array.find (\row -> row.node == id) rows) \row -> do
                  B.setProperty "value" row.content content
                  B.setText row.path path
          B.listen "change" false (const showPrompt) node
          showPrompt
          B.listen "submit" false (\event -> do
            B.preventDefault event
            B.setProperty "disabled" true submit
            launchAff_ do
              result <- try do
                text <- liftEffect $ B.property "value" content
                id <- liftEffect $ B.property "value" node
                saved <- await $ runEffectFn2 context.savePrompt id text
                liftEffect do
                  Ref.modify_ (map (\row -> if row.node == id then row {content=text,path=saved.path} else row)) prompts
                  showPrompt
                  runEffectFn1 context.toast "Prompt saved for subsequent decisions."
              liftEffect do
                for_ (leftMessage result) $ runEffectFn1 context.toast
                B.setProperty "disabled" false submit
            ) form
      liftEffect $ for_ (leftMessage outcome) $ runEffectFn1 context.toast
  pure {taskRow:mkEffectFn2 taskRow, renderTasks:mkEffectFn1 renderTasks,
    delegationMessages:mkEffectFn1 delegationMessages, taskCallControls:mkEffectFn1 taskCallControls, editDecisionPrompts}
  where
  maybeTimestamp Nothing = 0.0
  maybeTimestamp (Just turn) = dateParse turn.created
  leftMessage (Left error) = Just $ message error
  leftMessage (Right _) = Nothing

foreign import requireElement :: String -> B.Element -> Effect B.Element

main :: Effect Unit
main = B.expose "SapiensTasks" {mount:mkEffectFn1 mount, past:mkEffectFn1 (pure <<< past),
  element:mkEffectFn3 (\tag className content -> element tag className $ toMaybe content)}
