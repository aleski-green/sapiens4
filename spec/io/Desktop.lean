import io.Host

open Lean System
namespace Spec

def enabledControl (nodes : Array Json) (label : String) : Except String (Option Json) := do
  let candidates := nodes.filter fun node =>
    (node.getObjValAs? Bool "enabled").toOption == some true &&
    ["title", "description", "value"].any (fun key => (stringField node key).toOption == some label)
  match candidates.toList with
  | [] => return none
  | [button] => return some button
  | _ => throw s!"Ambiguous accessible control: {label}"


structure Desktop where
  driver : String
  pid : UInt32

def Desktop.invoke (desktop : Desktop) (command : String) (args : Array String := #[]) : IO Json := do
  let child ← IO.Process.spawn {
    cmd := desktop.driver, args := #[command, "--pid", toString desktop.pid] ++ args
    env := if Platform.isWindows || Platform.isOSX then #[] else
      #[("BLINDLY4_LINUX_TEXT_INPUT", some "keyboard")]
    stdin := .null, stdout := .piped, stderr := .piped }
  let stdout ← IO.asTask child.stdout.readToEnd .dedicated
  let stderr ← IO.asTask child.stderr.readToEnd .dedicated
  let exited ← IO.asTask child.wait .dedicated
  try
    let status ← untilSome s!"Blindly4 {command}" do
      if ← IO.hasFinished exited then return some (← IO.ofExcept exited.get)
      return none
    let response ← IO.ofExcept (← IO.wait stdout)
    unless status == 0 do
      let diagnostic ← IO.ofExcept (← IO.wait stderr)
      throw <| IO.userError s!"Blindly4 {command}: {diagnostic} {response}"
    IO.ofExcept <| Json.parse response
  finally
    unless ← IO.hasFinished exited do
      child.kill
      discard <| IO.ofExcept (← IO.wait exited)

def Desktop.find (desktop : Desktop) (args : Array String) : IO (Array Json) := do
  let found ← untilSome "a stable accessibility snapshot" do
    try
      return some (← desktop.invoke "find" (args ++ #["--depth", "50", "--limit", "1000"]))
    catch error =>
      let message := error.toString
      if Platform.isWindows && message.contains "0x80040201" then return none
      if !Platform.isWindows && !Platform.isOSX &&
          message.contains "org.freedesktop.DBus.Error.UnknownMethod" &&
          message.contains "Object does not exist at path" then return none
      throw error
  IO.ofExcept do
    fieldsMatch found (json% {truncated: false})
    found.getObjValAs? (Array Json) "matches"

def Desktop.findRole (desktop : Desktop) (role : String) : IO (Array Json) :=
  desktop.find #["--role", role]

def Desktop.button (desktop : Desktop) (label : String) : IO Json :=
  untilSome label do
    IO.ofExcept <| enabledControl ((← desktop.findRole "AXButton") ++ (← desktop.findRole "AXCheckBox")) label

def Desktop.pressControl (desktop : Desktop) (control : Json) (label : String) : IO Unit := do
  let path ← IO.ofExcept <| stringField control "path"
  let description := (stringField control "description").toOption.getD ""
  let guard := if description.isEmpty then #["--require-value-path", path, "--require-value", label]
    else #["--expect-description", description]
  try
    discard <| desktop.invoke "press" (#["--path", path] ++ guard)
  catch error => throw <| IO.userError s!"Press {label}: {error}"

def Desktop.clickButton (desktop : Desktop) (label : String) : IO Unit := do
  desktop.pressControl (← desktop.button label) label

def withDesktopConfig (use : FilePath → IO α) : IO α := do
  let config ← IO.FS.createTempDir
  try use config
  finally
    discard <| untilSome "profile cleanup" (do
      try
        if ← config.pathExists then IO.FS.removeDirAll config
        return some ()
      catch error =>
        if error.toString.contains "resource busy" || error.toString.contains "no such file or directory" ||
            error.toString.contains "directory not empty" then return none
        throw error) 20000 100

def withWindow (executable : FilePath) (arguments : Array String)
    (env : Array (String × Option String)) (use : Desktop → IO α) : IO α := do
  let root ← repoRoot
  let driver ← IO.getEnv "SAPIENS_TEST_BLINDLY4"
  let driver := driver.getD (root / "submodules/blindly4/.build" /
    (if Platform.isWindows then "windows/blindly4.exe" else "release/blindly4")).toString
  let child ← IO.Process.spawn {
    cmd := executable.toString, args := arguments, cwd := root
    env,
    stdin := .piped, stdout := .null }
  let desktop := Desktop.mk driver child.pid
  let exited ← IO.asTask child.wait .dedicated
  let poll := do
    if ← IO.hasFinished exited then return some (← IO.ofExcept exited.get)
    return none
  try
    if Platform.isOSX && arguments.contains "--fixture" then
      child.stdin.putStrLn (json% {width: 900, height: 680}).compress
      child.stdin.flush
    discard <| untilSome "fixture window" do
      if let some status ← poll then throw <| IO.userError s!"Desktop exited with {status}"
      try
        let windows ← desktop.findRole "AXWindow"
        return if windows.isEmpty then none else some ()
      catch error =>
        if error.toString.contains "not a running application" ||
            error.toString.contains "No visible windows" ||
            error.toString.contains s!"No accessible application for PID {child.pid}" then return none
        throw error
    discard <| desktop.invoke "activate"
    use desktop
  finally
    if (← poll).isNone then
      if Platform.isWindows then
        try
          let closed ← IO.Process.output {
            cmd := "powershell.exe"
            args := #["-NoProfile", "-Command", s!"(Get-Process -Id {child.pid}).CloseMainWindow() | Out-Null"],
            env := #[("PSModulePath", none)]}
          unless closed.exitCode == 0 do throw <| IO.userError closed.stderr
          discard <| untilSome "desktop shutdown" poll
        catch error =>
          child.kill
          throw error
      else child.kill
    discard <| untilSome "desktop shutdown" poll

def withDesktop (directory : FilePath) (use : Desktop → IO Unit) : IO Unit := withDesktopConfig fun config => do
  let root ← repoRoot
  -- These jobs exercise an existing workspace, not first-run storage selection.
  withHost directory fun _ => pure ()
  let launch := fun executable arguments => do
    withWindow executable arguments ((← fixtureEnvironment directory).push ("SAPIENS_CONFIG_DIR", some config.toString)) use
  if Platform.isOSX then
    let bundle ← IO.getEnv "SAPIENS_TEST_MACOS_APP"
    let executable := bundle.map (fun path => FilePath.mk path / "Contents/MacOS/Sapiens4")
    withHost directory fun host => launch (executable.getD (binary root "sapiens-macos")) #["--fixture", host.url ++ "/workspace/"]
  else if Platform.isWindows then
    launch (binary root "sapiens-windows") #["--data-dir", directory.toString, "--runtime-dir", root.toString]
  else
    launch (binary root "sapiens-linux") #["--data-dir", directory.toString]

end Spec
