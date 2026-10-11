# FlyBy

FlyBy is a macOS menu-bar companion driven by nearby aircraft observations. A nearby aircraft flies across the desktop, then becomes a clickable, dismissible details pill at the screen edge. The app includes a scrollable flight inspector, proximity and closest-approach logic, manual presentation safety, optional sound, and credit-aware OpenSky polling.

## Requirements

- macOS 14 or newer
- Swift 6.2 toolchain
- Full Xcode is recommended for running the GUI target and is required later for signing, entitlements, UI tests, and distribution. Core builds and tests work with Apple Command Line Tools.

## Build and test

```sh
sh .codex/verify.sh
```

The verification script builds the app and runs `FlyByCoreChecks`. It also runs the XCTest suite when full Xcode is available. The current machine's standalone Command Line Tools installation omits XCTest, so the framework-independent checks cover the critical deterministic paths there.

For the macOS desktop test, launch the development app bundle:

```sh
sh .codex/run-app.sh
```

The script builds the Swift package, places the executable in `.build/FlyBy.app` with the required location-purpose Info.plist, and opens it. A bare `swift run FlyBy` build can still exercise features that do not need macOS app-bundle metadata, but it cannot request Location Services permission. Click the menu-bar airplane, then choose **Preview mascot**. The preview is synthetic and makes no network requests. The parked **Details** pill has a close ×; **Hide mascot** in the menu also removes it.

For live data, expand **Location & atmosphere**, enter WGS-84 latitude and longitude, choose a radius, and click **Check now**. **Live watch** optionally polls every 5, 10, or 15 minutes and shows the maximum daily request count before it is enabled. Five-minute polling is at most 288 state requests/day while the app runs. FlyBy displays the server-reported remaining state credits and its request count for the current app session.

**Refresh My Location** requests one location fix from macOS only when clicked. The user may grant or deny the system permission; manual coordinates remain available. The coordinates are kept in memory. A new location fix does not make an OpenSky request until **Check now** or the next Live Watch poll.

The flight inspector's **Last observed** time is a data timestamp, not a live-tracking button. While Live Watch is on, an open inspector updates when a later scheduled poll sees the same aircraft inside the tracking area; it does not create extra requests. OpenSky's free anonymous access is sufficient for periodic snapshots within its credit allowance, not continuously animated second-by-second flight tracking.

When FlyBy selects a nearby live aircraft, it makes one ADSBDB request for the exact reported callsign and shows its listed origin and destination in the main aircraft card and inspector when available. This does not use OpenSky credits and is never polled. When there is no exact match, no callsign, or the lookup fails, FlyBy shows **N/A**; it does not fall back to schedule or nearby-airport inference. A callsign-based database route is not a verified itinerary for the particular aircraft overhead. No route request is made for the demo.

OpenSky does not use a single API key. Users can expand **OpenSky account** and enter the OAuth `client_id` and `client_secret` created on their OpenSky account page. The credentials are stored in macOS Keychain, access tokens remain in memory and are refreshed automatically, and **Use anonymous** removes the saved Keychain item. No credentials are embedded in the application.

## Current safety model

Manual pause and quiet/capture state modeling live in `PresentationState`. Automatic capture detection is intentionally not claimed yet; it needs the recorder compatibility spike described in the product spec. The clickable overlay uses a mascot-sized non-activating panel rather than a full-screen transparent window, and it is removed immediately when manually paused.

## Architecture

- `FlyByCore`: aircraft models, provider protocol, demo provider, proximity engine, cooldown state, and presentation decisions.
- `FlyByApp`: menu-bar UI, MapKit detail window, code-native vector mascot, one-shot Core Location request, sound, polling lifecycle, and AppKit overlay coordinator.
- The menu-bar airplane is stable across loading, nearby, paused, and provider-error states. The menu and its buttons use fixed opaque colors so macOS focus changes do not recolor them.
- The details inspector shows the OpenSky state-vector fields that are actually reported: callsign, ICAO24, inferred registration country, category, position, barometric/geometric altitude, ground speed, true track, vertical rate, squawk, special-purpose flag, position source, and timestamps. Missing values are labeled “Not reported.” Route and airline enrichment uses one exact ADSBDB callsign lookup; registration and exact model remain unavailable.
- `FlyByCoreTests`: deterministic distance, closest-pass, stale-data, cooldown, and presentation-guard tests.

## Privacy and data

Mascot preview is fully local. No analytics, FlyBy account, or persistent location storage is included. Core Location permission is requested only if the user presses **Refresh My Location**. A manual or scheduled live check sends the selected geographic bounding box and the computer's IP address to OpenSky Network. Polling is off by default and preferences remain in memory for this prototype. Optional OpenSky OAuth credentials are the sole persisted app data and remain in macOS Keychain. macOS itself stores the user's location-permission choice.

Selecting a nearby live aircraft with a callsign sends that callsign and the computer's IP address to ADSBDB so the route can appear in the main card. It sends neither your coordinates nor OpenSky credentials, does not poll ADSBDB, and keeps the result only in memory. ADSBDB's published route data carries a third-party reuse notice; confirm suitability and any required permissions before distributing FlyBy with this integration.

OpenSky currently documents per-endpoint quotas of 400 daily state credits for anonymous access, 4,000 daily for standard authenticated users, 8,000 daily for active feeders, and 14,400 hourly for licensed users. A small FlyBy bounding box costs one state credit. OpenSky's current terms say operational REST API integrations and commercial use require a written license; authentication or a higher quota does not itself grant that license. Confirm suitable terms before distributing or operating FlyBy beyond personal testing.
