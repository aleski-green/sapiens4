import io.Desktop

open Lean System
namespace Spec

abbrev CryptoWindow := Json → IO Json

-- Preserve Unicode while using the Linux driver's guarded ASCII keyboard path.
def fixtureRequest (value : Json) : String :=
  let escape := fun (n : Nat) =>
    let digits := Nat.toDigits 16 n
    "\\u" ++ String.ofList (List.replicate (4 - digits.length) '0' ++ digits)
  value.compress.foldl (fun result c => result ++
    if c.toNat < 127 then String.singleton c
    else if c.toNat < 65536 then escape c.toNat
    else escape (55296 + (c.toNat - 65536) / 1024) ++
      escape (56320 + (c.toNat - 65536) % 1024)) ""

example : (Json.parse (fixtureRequest (toJson "café 🧬"))).toOption == some (toJson "café 🧬") := by native_decide
example : (fixtureRequest (toJson (String.singleton (Char.ofNat 127)))).toList.all
    (fun c => c.toNat ≥ 32 && c.toNat < 127) := by native_decide

def Desktop.fixtureField (desktop : Desktop) (label : String) : IO Json :=
  untilSome label do
    -- Readonly fields need not be enabled or exposed with an editable-text role.
    let fields ← if Platform.isWindows || Platform.isOSX then
      desktop.findRole (if Platform.isWindows then "AXTextField" else "AXTextArea")
      else desktop.find #["--description", label]
    let candidates := fields.filter fun node =>
      ["title", "description"].any (fun key => (stringField node key).toOption == some label)
    match candidates.toList with
    | [] => return none
    | [field] => return some field
    | _ => throw <| IO.userError s!"Ambiguous fixture field: {label}"

def withBrowserFixture (host : Host) (use : Desktop → CryptoWindow → IO α) : IO α :=
  withDesktopConfig fun profile => do
    let configured ← IO.getEnv "SAPIENS_TEST_BROWSER"
    let programFiles ← IO.getEnv "PROGRAMFILES"
    let programFilesX86 ← IO.getEnv "PROGRAMFILES(X86)"
    let candidates : List String := if Platform.isOSX then
      ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"]
      else if Platform.isWindows then [
        programFiles.getD "C:/Program Files" ++ "/Google/Chrome/Application/chrome.exe",
        programFilesX86.getD "C:/Program Files (x86)" ++ "/Microsoft/Edge/Application/msedge.exe"]
      else ["/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome"]
    let some browser ← (configured.toList ++ candidates).findM? (fun path => (FilePath.mk path).pathExists)
      | throw <| IO.userError "Install Chrome/Chromium/Edge or set SAPIENS_TEST_BROWSER"
    withWindow browser #["--user-data-dir=" ++ profile.toString, "--no-first-run",
      "--no-default-browser-check", "--disable-background-networking", "--disable-extensions",
      "--force-renderer-accessibility", "--app=" ++ host.url ++ "/workspace/#spec"] #[] fun desktop => do
      discard <| desktop.fixtureField "Fixture request"
      discard <| untilSome "crypto connection" do
        return if (← host.api "GET" "/api/host/crypto").getObjValD "connected" == toJson true then some () else none
      let serial ← IO.mkRef (0 : Nat)
      let call := fun (input : Json) => do
        serial.modify (· + 1)
        let id ← serial.get
        let request := fixtureRequest (json% {id: $(id), input: $(input)})
        let field ← desktop.fixtureField "Fixture request"
        discard <| desktop.invoke "paste" #["--target-path", ← IO.ofExcept <| stringField field "path", "--text", request]
        untilSome "fixture result" do
          let raw ← IO.ofExcept <| stringField (← desktop.fixtureField "Fixture result") "value"
          match Json.parse raw with
          | .ok response =>
            if response.getObjValD "id" != toJson id then return none
            if response.getObjValD "error" != Json.null then throw <| IO.userError response.compress
            return some (response.getObjValD "value")
          | .error _ => return none
      use desktop call

def withCryptoSession (host : Host) (use : CryptoWindow → IO α) : IO α :=
  withBrowserFixture host (fun _ call => use call)

def withCryptoWindow (host : Host) (use : IO α) : IO α :=
  withCryptoSession host (fun _ => use)

def withCryptoHost (directory : FilePath) (use : Host → IO α) : IO α :=
  withHost directory fun host => withCryptoWindow host (use host)

end Spec
