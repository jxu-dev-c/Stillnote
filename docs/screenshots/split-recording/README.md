# Split recording acceptance screenshots

Captured from the native debug app with an isolated `STILLNOTE_DATA_DIR` and synthetic audio, transcripts and context. No private meeting content is included.

The progress capture uses a separate 90-minute synthetic workshop with the QA process temporarily CPU-throttled using STOP/CONT signals. No artificial delay or screenshot hook is present in the application code. All other captures use the normal-speed 50-minute flow.

Verified: cancel leaves the original untouched; changing the threshold immediately changes visibility; successful replacement persists after restart; all four source sentences appear exactly once across the three parts; original audio is removed only after replacement; notes, links and speaker identities survive.

## Default 50-minute threshold

![Default 50-minute threshold](01-default-threshold.jpg)

## Threshold changed to 51 minutes

![Threshold changed to 51 minutes](02-custom-threshold.jpg)

## 50-minute recording hidden below the custom threshold

![50-minute recording hidden below the custom threshold](02b-custom-threshold-applied.jpg)

## Split action at the 50-minute threshold

![Split action at the 50-minute threshold](03-eligible-recording.jpg)

## Replacement confirmation with all part names and durations

![Replacement confirmation with all part names and durations](04-confirmation.jpg)

## Short recording without a split action

![Short recording without a split action](05-below-threshold.jpg)

## Screen recording excluded

![Screen recording excluded](06-video-excluded.jpg)

## Export in progress with conflicting actions disabled

![Export in progress with conflicting actions disabled](07-splitting.jpg)

## Part 1 opens with an empty summary

![Part 1 opens with an empty summary](08-empty-summary.jpg)

## Part 2 transcript starts at zero

![Part 2 transcript starts at zero](09-local-transcript.jpg)

## Independent part playback

![Independent part playback](10-part-playback.jpg)

## Notes and links preserved in each part

![Notes and links preserved in each part](11-copied-context.jpg)

## Original replaced by 20-, 20-, and 10-minute parts

![Original replaced by 20-, 20-, and 10-minute parts](12-result-list.jpg)

## Revision: direct input and trim visibility

The threshold now uses a text field; valid integers save immediately. Empty, nonnumeric,
and out-of-range input retain the last valid saved value and show an inline message.
The default/custom screenshots above have been replaced with the final text-input UI.

A synthetic recording with three minutes of cleanup metadata shows only the split action
when eligible. Raising its threshold to 51 minutes restores the trim label and hides split.

![Split action hides trim metadata](13-split-hides-trim.jpg)

![Trim remains when split is unavailable](14-trim-without-split.jpg)

![Invalid threshold retains the saved value](15-invalid-threshold.jpg)
