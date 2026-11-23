# Sapiens4 art direction

The application follows the supplied **Sapiens4 Art Direction 2026** reference:
neutral grounds, floating round cards, keyboard faces and a single pink primary
action. `app/theme/sapi-theme.css` is the final visual layer, loaded after the
structural and feature stylesheets.

## Shared tokens

| Role | Light | Dark |
| --- | --- | --- |
| Ground | `#F2F2F2` | `#111111` |
| Card | `#FFFFFF` | `#1C1C1C` |
| Soft surface | `#F2F2F2` | `#2A2A2A` |
| Ink | `#111111` | `#F5F5F5` |
| Quiet text | `#6B6B6B` | `#A3A3A3` |
| Line | `#E6E6E6` | `#333333` |

Action/Chiefy `#F9BDD0`, blush `#F08FB0`, Curio `#CFC4F2`, Buildly `#FBE58A`
and Nerd `#BFE3FA` stay identical in both themes. Text on pastel surfaces is
always `#111111`. Blush is decorative progress color, never body text.

Main panes and dialogs use 13px corners. Desktop controls are 28–34px high
with 6px corners; touch controls retain 44px hit areas. Navigation is plain text
and icons with a subtle selected surface or a single underline. Keyboard focus
alone receives a contrasting outline. The sidebar sits on the ground color;
conversation and workspace use the card surface. Assistant text is unboxed and
user messages use a neutral soft surface.

DM Sans is the interface font, Zen Maru Gothic is the face font (300 for artwork,
500 for chips), and IBM Plex Mono is the code font. All four WOFF2 files are
bundled with their full glyph sets. Font licenses ship in `license/fonts/`.

## Compact interface

The component sheet informs shared typography, color, spacing, and behavior;
controls are sized for their context in the complete screen.

- Desktop toolbar buttons are 28px; form actions are 32px and fields 34px.
  Pointer-coarse layouts keep 44px actions and 16px editable text.
- Roster rows use 56px minimum height and small pastel face chips. Headers use
  the same compact avatar instead of a large profile tile.
- Navigation and selection never imitate keyboard focus. There are no selected
  button outlines or nested segment containers. Focus-visible remains explicit.
- Settings, tasks, relay entries, and Updates use open rows and subtle separators.
  Floating menus and dialogs retain a surface for separation from their backdrop.
- Pink is reserved for primary actions. Status text and marks remain readable
  without relying on color. Every theme token uses the original reference palette.
- Conversation text, native controls, scrolling, hidden panes, and reduced-motion
  preferences retain their functional behavior.

## Components

- Shell: header, pane controls, connection status, corpora menus, update control.
- Roster: search, scope segments, selected rows, avatar chips, Group badges,
  shared-computer card.
- Conversation: assistant text, user bubbles, activity tabs and menus,
  composer, mentions, attachments, recording controls, warnings and live work.
- Work: task and routine cards, state marks, disclosures, results, code and events.
- Workspace: browser tabs, address entry, bookmarks, menus, document content,
  file previews and empty state.
- Dialogs: application menu, workspace settings, model settings, provider setup,
  Sapi/Group forms, attachments, local corpora, remote pairing and relay management.
- First run: storage choices, consent, installation, empty corpora and legal pages.
- Identity: Chiefy artwork, favicon, install icons and Windows icon resources.

Secondary actions are grey. The composer owns the pink action during chat; an
open dialog neutralizes the background send control and owns its primary action.
Stop/cancel and application-update controls stay neutral.

## Faces and accessibility

`Sapiens.Art` owns nine decorative moods plus the Chiefy SVG. Artwork has
`aria-hidden="true"`; names, status labels and instructions remain real text.
White heads and dark facial marks do not invert in dark mode. Compact avatar
chips use the stored character marks without adding outer parentheses. Existing
names and custom facial expressions remain unchanged. Legacy default palette
values are translated at render time; colors outside the reviewed palette display
as action pink. Stored custom colors remain intact; no avatar data is rewritten.

Task marks distinguish complete (`●`), active (`◎`), waiting (`○`) and attention
(`!`) in addition to their text labels. Focus uses a contrasting ink outline.
Motion is suppressed for reduced-motion preferences.

## Runtime delivery

The font files are registered in `Assets.publicAssets`, which also places them
in native packages. `/assets/fonts/` resolves the theme stylesheet's relative
font URLs. `/theme/fonts/` supports legal documents opened over HTTP and the
same relative paths in local native files. The relay and bootstrap policies
allow same-origin fonts. The remote service worker caches the font assets; its
shell version marker is kept in sync with the relay's content-hash replacement.

## Review checklist

Check light/dark themes, 320–1440px widths, all three panes and individual pane
visibility, long names, custom faces, menu placement, keyboard focus, chat and
voice controls, all dialog kinds, onboarding and offline remote typography.
Native webview geometry and platform behavior still require the desktop suite
in `docs/testing.md` when qualifying a release.

## Rendered previews

These are the actual PureScript view components rendered with sample data in
Chromium, rather than HTML mockups. They are visual fixtures, not live accounts.

[Light desktop](art-direction/light.png) · [Dark desktop](art-direction/dark.png) ·
[Mobile conversation](art-direction/mobile.png) · [Mobile model settings](art-direction/models-mobile.png)

Validation for this change: the full PureScript UI compiled and all eight
production bundles built. Browser checks covered 29 configurations (five widths
in both themes plus 19 component scenes), with no runtime errors or horizontal
overflow. Automated WCAG A/AA audits passed for the audited desktop/mobile chat
and component scenes. Additional checks covered composer target sizes and
spacing, typed input, theme/menu/dialog rendering, hidden panes, single-pane
sizing, keyboard focus, setup/legal presentation and the mobile model selectors.
Font route resolution, offline font-cache membership, relay cache-version
replacement and Windows icon checksums were verified separately. These checks
used the app's view components with fixture state; they do not replace the native
end-to-end suite, which was not run for this change.

## Usability refinement

The workspace applies [Apple's layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout)
on hierarchy, alignment and consistent spacing, and [WCAG 2.2 target-size guidance](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum/).
Desktop rows and secondary controls use denser spacing; mobile controls keep 44px
touch targets. Main controls have explicit labels on wide screens, active roster
rows have a non-color selection marker, and focused controls retain an ink outline.
Conversation headers and tabs leave more room for the work. Wide chat text has a
bounded reading width. Shared-computer status uses user-facing language.

Updates use aligned columns on wide panes and stacked labeled rows on narrow panes.
Dates omit subsecond noise; the full timestamp remains on the time element.
Only meaningful payloads offer disclosure, operable by keyboard. Empty feeds explain
what belongs there. The single-purpose Updates menu and its inactive placeholder
are removed. Application start/stop events are no longer recorded; the v00.02.01
migration removes existing lifecycle entries from stored event lists (see
[migration contract](../migrations/README.md)).

Refinement checks: 49 browser configurations across light/dark, 320–1440px,
chat, populated/empty Updates and secondary component scenes passed automated
WCAG A/AA checks, including the WCAG 2.2 target-size rule, with no script errors
or page/Updates horizontal overflow. The native binaries and all production
bundles built. The migration suite covers the real cleanup step, exact matching,
all owners, skip-version upgrade, interrupted transactions, malformed inputs,
rollback, unversioned adoption and repeat opening. Two host startup/shutdown
cycles retained meaningful events and produced no lifecycle noise. Keyboard
expansion/collapse, non-expandable empty payloads, a nine-Sapi roster with Group
badges, pane resizing and draft input also passed focused interaction checks.

[Desktop Updates](art-direction/updates-dark.png) · [Narrow Updates](art-direction/updates-mobile.png)

## Golden-ratio sizing

The conversation/workspace tracks divide their available width at 1:1.618 on
wide windows, after the roster and gaps. Minimum pane widths take priority.
Intermediate desktop windows use the same ratio between roster and work area.
Spacing follows 8 / 13 / 21 / 34px; card/inner radii use 21 / 13px. The 13 / 21 /
34px type anchors are complemented by a practical 16px body half-step and 1.618
chat line-height. Touch targets remain at least 44px; narrow layouts prioritize
readability over maintaining the wide-screen ratio.
