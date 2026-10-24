# Split recording acceptance screenshots

Captured from the native debug app with an isolated `STILLNOTE_DATA_DIR` and synthetic audio, transcripts and context. No private meeting content is included.

The progress capture uses a separate 90-minute synthetic workshop with the QA process temporarily CPU-throttled using STOP/CONT signals. No artificial delay or screenshot hook is present in the application code. All other captures use the normal-speed 50-minute flow.

Verified: cancel leaves the original untouched; changing the threshold immediately changes visibility; successful replacement persists after restart; all four source sentences appear exactly once across the three parts; original audio is removed only after replacement; notes, links and speaker identities survive.

## Default 50-minute threshold

![Default 50-minute threshold](01-default-threshold.png)

## Threshold changed to 51 minutes

![Threshold changed to 51 minutes](02-custom-threshold.png)

## 50-minute recording hidden below the custom threshold

![50-minute recording hidden below the custom threshold](02b-custom-threshold-applied.png)

## Split action at the 50-minute threshold

![Split action at the 50-minute threshold](03-eligible-recording.png)

## Replacement confirmation with all part names and durations

![Replacement confirmation with all part names and durations](04-confirmation.png)

## Short recording without a split action

![Short recording without a split action](05-below-threshold.png)

## Screen recording excluded

![Screen recording excluded](06-video-excluded.png)

## Export in progress with conflicting actions disabled

![Export in progress with conflicting actions disabled](07-splitting.png)

## Part 1 opens with an empty summary

![Part 1 opens with an empty summary](08-empty-summary.png)

## Part 2 transcript starts at zero

![Part 2 transcript starts at zero](09-local-transcript.png)

## Independent part playback

![Independent part playback](10-part-playback.png)

## Notes and links preserved in each part

![Notes and links preserved in each part](11-copied-context.png)

## Original replaced by 20-, 20-, and 10-minute parts

![Original replaced by 20-, 20-, and 10-minute parts](12-result-list.png)

