# Design System

## Direction

A small native macOS setup utility used at a desk in ordinary light. The interface follows the active system appearance and stays quiet enough to scan in a few seconds.

## Color

- Use semantic SwiftUI colors so light and dark modes follow macOS.
- Use the system accent for selection and the primary action.
- Reserve green for verified success, amber for changed configuration, and red for actionable failures.
- Avoid gradients and decorative color fields.

## Typography

- Use SF Pro through SwiftUI system styles.
- Window title: `.title2` with semibold weight.
- Section title: `.headline`.
- Body and controls: native body sizing.
- Supporting text: `.callout` or `.caption`, secondary color.

## Layout

- Fixed initial window around 620 by 500 points, resizable within practical limits.
- Use one unframed vertical workflow with 24-point outer margins.
- Use a native segmented picker for client selection.
- Keep labels above fields and align form controls to one column.
- Place the primary action at the lower trailing edge.

## Components

- Native `Picker`, `TextField`, `SecureField`, `Button`, `ProgressView`, and alerts.
- Status is an inline row with a symbol, short label, and relevant actions.
- Errors appear next to the workflow they block, with details available through disclosure.
- Buttons use standard bordered and bordered-prominent styles.

## Motion

- Use only native state transitions and progress feedback.
- Honor Reduce Motion automatically.
