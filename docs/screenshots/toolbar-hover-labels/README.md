# Toolbar label verification

These are unedited captures of a running native preview that uses the production
`DetailToolbar`, `ToolbarIconButton`, page switcher, and label presenter. All
content is synthetic; actions only update the preview's status text.

Build with `./scripts/preview-toolbar-help.sh`, then open
`build/ToolbarPreview.app`. The preview never opens a meeting library or invokes
recording, transcription, naming, or summary services.

- `dark-keyboard.jpg`: dark appearance; focused Transcribe Again label.
- `light-keyboard.jpg`: light appearance; focused Regenerate Summary label.
- `compact-keyboard.jpg`: compact icon-only page switcher; focused Transcript label.

Labels use the same `Capsule` shape as the tabs, with a full-point border and a
composited shadow. The top edge was checked at 5× magnification for gaps. The opaque
surface keeps text independent of content behind it. Short labels fit their text;
explanations wrap at a maximum width of 280 points.

## Verified

- Tab/Shift-Tab navigation through icon actions and page buttons, with disabled
  Auto-Tag skipped; visible native focus indication and one label at a time.
- Space activates the focused synthetic action; Escape dismisses the label and
  preserves focus. Accessibility activation also reaches the action.
- Accessibility tree exposes the disabled Auto-Tag button's name and help
  (`Learn voices in Settings → Speakers first.`), and the selected page state.
  The decorative label does not create a duplicate accessible element.
- Full project check script, including regressions for delayed presentation,
  cancellation before presentation, and supersession by another focused control.

## Manual verification still needed

The available UI automation has no reliable pointer-dwell operation. Pointer
entry/exit on enabled and disabled controls, actual VoiceOver speech, and system
Increase Contrast/Reduce Transparency settings need a human pass. The preview's
high-contrast appearance toggle only changes its window appearance; it does not
change or certify the system accessibility settings. Compact native menu operation
was not verified by the automation.
