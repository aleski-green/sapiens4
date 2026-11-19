import io.CryptoWindow

open Lean
namespace Spec.SystemJobs

def preserveBrowserApplicationBehavior : IO Unit := IO.FS.withTempDir fun directory =>
  withHost directory fun host => withBrowserFixture host fun desktop browser => do
    let check := fun (operation : String) => do
      IO.ofExcept <| requireThat operation ((← browser (json% {operation: $(operation)})) == toJson true)
    let activate := fun (control : Json) (label key : String) => do
      if System.Platform.isWindows || System.Platform.isOSX then
        desktop.pressControl control label
      else
        -- Chrome's AT-SPI controls may lack a press action; use their keyboard interaction.
        let role ← IO.ofExcept <| stringField control "role"
        let title ← IO.ofExcept <| stringField control "title"
        let description ← IO.ofExcept <| stringField control "description"
        discard <| desktop.invoke "focus" #["--path", ← IO.ofExcept <| stringField control "path"]
        IO.ofExcept <| fieldsMatch (← desktop.invoke "focused")
          (json% {pid: $(desktop.pid.toNat), role: $(role), title: $(title), description: $(description), enabled: true, focused: true})
        discard <| desktop.invoke "key" #["--key", key]
    let click := fun label => do activate (← desktop.button label) label "space"
    check "verify"
    check "application"
    check "setup"
    click "Accept terms"
    check "accepted"
    click "Use another folder"
    check "picking"
    check "picked"
    click "Continue"
    check "submitted"
    check "error"
    click "Accept terms"
    check "revoked"
    let link ← untilSome "Privacy Policy" do
      IO.ofExcept <| enabledControl (← desktop.findRole "AXLink") "Privacy Policy"
    activate link "Privacy Policy" "enter"
    check "legal"

end Spec.SystemJobs
