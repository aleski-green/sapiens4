import io.Host

open Lean System
namespace Spec.User

def retainModelSettingsAcrossRestart : IO Unit := IO.FS.withTempDir fun directory => do
  let defaults := json% {provider: "codex", model: "gpt-6-astra", effort: "medium"}
  let (owner, saved) ← withHost directory fun host => do
    let owner ← host.agent "Reviewer"
    let overrides := Json.mkObj [(owner, json% {provider: "codex", model: "gpt-6-luna", effort: "low"})]
    let saved ← host.api "PUT" "/api/model-settings" (json% {revision: 0, defaults: $(defaults), overrides: $(overrides)})
    for (body, status) in [
      (json% {revision: 0, defaults: $(defaults), overrides: {}}, 409),
      (json% {revision: 1, defaults: {provider: "unknown", model: "unsupported", effort: "medium"}, overrides: {}}, 400),
      (json% {revision: 1, defaults: $(defaults), overrides: {"missing-sapi": $(defaults)}}, 404)] do
      discard <| host.api "PUT" "/api/model-settings" body status
      IO.ofExcept <| requireThat "invalid save changed model settings" ((← host.api "GET" "/api/model-settings") == saved)
    return (owner, saved)
  withHost directory fun host => do
    IO.ofExcept <| requireThat "restart changed model settings" ((← host.api "GET" "/api/model-settings") == saved)
    discard <| host.completedMessage owner "Use my saved model override"
    let inherited ← host.api "PUT" "/api/model-settings" (json% {revision: 1, defaults: $(defaults), overrides: {}})
    IO.ofExcept <| fieldsMatch inherited (json% {defaults: $(defaults), overrides: {}})
    discard <| host.completedMessage owner "Use the corpora default again"

def keepOneEnvironmentAcrossRestart : IO Unit := IO.FS.withTempDir fun directory => IO.FS.withTempDir fun other => do
  let environment := fun (host : Host) => do
    let corpora ← host.api "GET" "/api/corpora"
    IO.ofExcept <| corpora.getObjVal? "environment" >>= (stringField · "id")
  let first ← withHost directory environment
  let again ← withHost directory environment
  let elsewhere ← withHost other environment
  IO.ofExcept <| requireThat "restart changed the environment" (!first.isEmpty && again == first)
  IO.ofExcept <| requireThat "two data folders shared one environment" (elsewhere != first)

def shareHistoryWithoutDeviceKeys : IO Unit := IO.FS.withTempDir fun directory => do
  withHost directory fun host => do
    let corpora ← host.api "GET" "/api/corpora"
    let whole ← host.api "GET" "/api/yoke/history?after=0"
    let later ← host.api "GET" "/api/yoke/history?after=1"
    let rejected ← host.api "GET" "/api/yoke/history?after=first" none 400
    IO.ofExcept do
      let reason ← stringField rejected "error"
      requireThat "bad cursor was not explained" (!reason.isEmpty)
      let environment ← corpora.getObjVal? "environment" >>= (stringField · "id")
      requireThat "history named another environment" ((← stringField whole "environment") == environment)
      let first ← (← whole.getObjValAs? (Array Json) "appends").mapM (·.getObjValAs? Nat "appendId")
      let rest ← (← later.getObjValAs? (Array Json) "appends").mapM (·.getObjValAs? Nat "appendId")
      requireThat "history missed the first write" (first.contains 1)
      requireThat "history repeated writes before the cursor" (rest.all (· > 1))
      requireThat "history shared a device-only key" ((whole.compress.splitOn "local/").length == 1)

private def mcpSession (url : String) (requests : Array Json) : IO (Array Json) := do
  let root ← repoRoot
  let handshake := json% {jsonrpc: "2.0", id: 0, method: "initialize", params: {
    protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "spec", version: "1"}}}
  let input := String.intercalate "\n" ((#[handshake] ++ requests).toList.map Json.compress) ++ "\n"
  let output ← IO.Process.output {cmd := (binary root "sapiens4").toString, args := #["mcp", "--url", url], cwd := root} (some input)
  unless output.exitCode == 0 do throw <| IO.userError s!"MCP failed: {output.stderr}"
  let replies ← IO.ofExcept <| (output.stdout.trimAscii.toString.splitOn "\n").toArray.mapM Json.parse
  IO.ofExcept do
    requireThat "missing MCP replies" (replies.size == requests.size + 1)
    fieldsMatch (replies[0]!.getObjValD "result") (json% {protocolVersion: "2025-11-25"})
    for index in [:replies.size] do
      fieldsMatch replies[index]! (json% {id: $(index)})
  return replies.extract 1 replies.size

private def tool (id : Nat) (name : String) (arguments : Json := json% {}) : Json :=
  json% {jsonrpc: "2.0", id: $(id), method: "tools/call", params: {name: $(name), arguments: $(arguments)}}

private def toolBody (reply : Json) : Except String Json := do
  let result ← reply.getObjVal? "result"
  fieldsMatch result (json% {isError: false})
  let content ← result.getObjValAs? (Array Json) "content"
  Json.parse (← stringField content[0]! "text")

def completeWorkThroughMcp : IO Unit := IO.FS.withTempDir fun directory => do
  withHost directory fun host => do
    let owner ← host.chief
    let corpora ← IO.ofExcept <| stringField ((← host.state).getObjValD "corpora") "id"
    let replies ← mcpSession host.url #[
      json% {jsonrpc: "2.0", id: 1, method: "tools/list", params: {}},
      tool 2 "corpora",
      tool 3 "sapis" (json% {corpora: $(corpora)}),
      tool 4 "send" (json% {corpora: $(corpora), sapi: $(owner), text: "Review release readiness"}),
      tool 5 "chat" (json% {corpora: $(corpora), sapi: $(owner), limit: 1, wait: 30})]
    IO.ofExcept do
      let tools ← (replies[0]!.getObjValD "result").getObjValAs? (Array Json) "tools"
      requireThat "MCP tool catalog changed" ((← tools.mapM (fun item => stringField item "name")) == #["corpora", "sapis", "chat", "send", "lifecycle"])
      discard <| uniqueRecord (← toolBody replies[1]!) "id" (toJson corpora)
      discard <| uniqueRecord (← toolBody replies[2]!) "id" (toJson owner)
      let sent ← toolBody replies[3]!
      let turn ← uniqueRecord (← toolBody replies[4]!) "id" (← sent.getObjVal? "id")
      fieldsMatch turn (json% {status: "done"})
    let lifecycle ← mcpSession host.url #[
      tool 1 "lifecycle" (json% {corpora: $(corpora), action: "pause"}),
      tool 2 "send" (json% {corpora: $(corpora), sapi: $(owner), text: "Refuse while paused"}),
      tool 3 "lifecycle" (json% {corpora: $(corpora), action: "activate"})]
    IO.ofExcept do
      fieldsMatch (← toolBody lifecycle[0]!) (json% {status: "paused"})
      fieldsMatch (lifecycle[1]!.getObjValD "result") (json% {isError: true})
      fieldsMatch (← toolBody lifecycle[2]!) (json% {status: "active"})

end Spec.User
