import io.Host

open Lean
namespace Spec.SystemJobs

def runStorageTool (name : String) (args : Array String) : IO IO.Process.Output := do
  let root ← repoRoot
  IO.Process.output {cmd := (binary root name).toString, args, cwd := root}

def preserveAtomicStorage : IO Unit := do
  let result ← runStorageTool "sapiens-storage-check" #[]
  IO.ofExcept <| requireThat result.stderr (result.exitCode == 0)

def preserveInterruptedWorkDuringUpgrade : IO Unit := IO.FS.withTempDir fun directory => do
  let fixture ← runStorageTool "sapiens-storage-check" #["--legacy-fixture", directory.toString]
  IO.ofExcept <| requireThat fixture.stderr (fixture.exitCode == 0)
  let file := directory / "agentpy/agents/sapi_saved/state.json"
  let original ← IO.FS.readFile file
  let database ← IO.FS.readBinFile (directory / "corpora.sqlite3")
  let root ← repoRoot
  let refused ← IO.Process.output {
    cmd := (binary root "sapiens4").toString
    args := #["--desktop", "--port", "0", "--data-dir", directory.toString]
    cwd := root, env := ← fixtureEnvironment directory} (some "")
  IO.ofExcept <| requireThat "startup silently migrated legacy data" (refused.exitCode != 0 && !(← (directory / "state.lmdb").pathExists))
  IO.FS.writeFile file "corrupt legacy state"
  let failed ← runStorageTool "sapiens-migrate" #["--data-root", directory.toString, "--config-root", directory.toString]
  IO.ofExcept <| requireThat "failed migration published data or a build marker"
    (failed.exitCode != 0 && !(← (directory / "state.lmdb").pathExists) && !(← (directory / "data-build.json").pathExists))
  IO.FS.writeFile file original
  for _ in [0:2] do
    let migrated ← runStorageTool "sapiens-migrate" #["--data-root", directory.toString, "--config-root", directory.toString]
    IO.ofExcept <| requireThat migrated.stderr (migrated.exitCode == 0)
    withHost directory fun host => do
      let recovered ← host.awaitTurn "saved-review" "interrupted"
      IO.ofExcept do
        fieldsMatch recovered (json% {input: "Review the proposal", status: "interrupted"})
        requireThat "missing recovery explanation" ((← stringField recovered "error").contains "retry")
      let marker ← IO.ofExcept <| Json.parse (← IO.FS.readFile (directory / "data-build.json"))
      IO.ofExcept <| requireThat "wrong data build" (marker == json% "v00.02.00")
      let pulse ← IO.ofExcept <| (← host.state).getObjVal? "pulse"
      IO.ofExcept <| fieldsMatch pulse (json% {bpm: 120})
      IO.ofExcept <| requireThat "upgrade ran a provider call" (!(← (directory / "fixture-prompts").pathExists))
    IO.ofExcept <| requireThat "migration changed legacy state" ((← IO.FS.readFile file) == original)
    IO.ofExcept <| requireThat "migration changed legacy SQLite" ((← IO.FS.readBinFile (directory / "corpora.sqlite3")) == database)
  IO.ofExcept <| requireThat "workspace note was not migrated" ((← IO.FS.readFile (directory / "workspaces/sapi_saved/Notes.html")).contains "Preserve this private note")

def recoverSavedWorkAfterStorageRepair : IO Unit := IO.FS.withTempDir fun directory => do
  let owner ← withHost directory fun host => do
    let owner ← host.chief
    let root ← repoRoot
    let contender ← IO.Process.output {
      cmd := (binary root "sapiens4").toString
      args := #["--desktop", "--port", "0", "--data-dir", directory.toString]
      cwd := root, env := ← fixtureEnvironment directory} (some "")
    IO.ofExcept <| requireThat "a second host failed to respect the data-directory lock"
      (contender.exitCode != 0 && contender.stderr.contains "Another Sapiens4 server")
    return owner
  let marker := directory / "data-build.json"
  let saved ← IO.FS.readFile marker
  IO.FS.writeFile marker "\"v99.00.00\""
  let root ← repoRoot
  let incompatible ← IO.Process.output {
    cmd := (binary root "sapiens4").toString
    args := #["--desktop", "--port", "0", "--data-dir", directory.toString]
    cwd := root, env := ← fixtureEnvironment directory} (some "")
  IO.ofExcept <| requireThat "incompatible build data were silently opened" (incompatible.exitCode != 0)
  IO.FS.writeFile marker saved
  withHost directory fun host => do
    IO.ofExcept <| requireThat "repair changed the saved owner" ((← host.chief) == owner)
    IO.ofExcept <| requireThat "repair ran a provider call" (!(← (directory / "fixture-prompts").pathExists))

def releaseExclusiveComputerAccessOnCancellation : IO Unit :=
  IO.FS.withTempDir fun directory => withHost directory fun host => do
    let chief ← host.chief
    let colleague ← host.agent "Operator"
    let acquire := json% {op: "computer_acquire"}
    discard <| host.control chief acquire 409
    let prompts := directory / "fixture-prompts"
    IO.FS.createDirAll prompts
    IO.FS.writeFile (prompts / "hold") ""
    try
      let first ← host.submit chief "Review the workspace"
      let second ← host.submit colleague "Check the workspace"
      discard <| untilSome "both active provider calls" do
        let calls := (← prompts.readDir).filter (·.fileName != "hold")
        return if calls.size == 2 then some () else none
      IO.ofExcept <| fieldsMatch (← host.control chief acquire) (json% {owner: $(chief)})
      let denied ← request host.url "POST" ("/api/agents/" ++ colleague ++ "/control") acquire
      let lease ← IO.ofExcept <| (← host.state).getObjVal? "computer"
      IO.ofExcept do
        requireThat "concurrent computer access was accepted" (denied.status == 409)
        fieldsMatch lease (json% {owner: $(chief)})
      discard <| host.api "POST" ("/api/agents/" ++ chief ++ "/turns/" ++ (← IO.ofExcept first.getStr?) ++ "/cancel") (json% {})
      discard <| untilSome "release of the cancelled turn's lease" do
        let state ← host.state
        let owner ← IO.ofExcept do (← state.getObjVal? "computer").getObjVal? "owner"
        return if owner == .null then some () else none
      IO.ofExcept <| fieldsMatch (← host.control colleague acquire) (json% {owner: $(colleague)})
      IO.FS.removeFile (prompts / "hold")
      discard <| host.awaitTurn second "done"
      let computer ← IO.ofExcept <| (← host.state).getObjVal? "computer"
      IO.ofExcept <| fieldsMatch computer (json% {owner: null})
    finally
      if ← (prompts / "hold").pathExists then IO.FS.removeFile (prompts / "hold")

end Spec.SystemJobs
