import AppKit
import FlyByCore
import SwiftUI

@main
struct FlyByApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "airplane.circle.fill")
                .accessibilityLabel("FlyBy")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: AppStatus = .monitoring
    @Published private(set) var nearest: AircraftCandidate?
    @Published private(set) var nearestRoute: FlightRoute?
    @Published private(set) var isLookingUpNearestRoute = false
    @Published private(set) var suppressedCount = 0
    @Published var radiusKilometers = 10.0
    @Published var latitude = 12.9716
    @Published var longitude = 77.5946
    @Published var presentationState = PresentationState()
    @Published var soundEnabled = false
    @Published var watchAutomatically = false {
        didSet { restartWatchTask() }
    }
    @Published var pollingCadence = PollingCadence.fiveMinutes {
        didSet { if watchAutomatically { restartWatchTask() } }
    }
    @Published private(set) var remainingCredits: Int?
    @Published private(set) var sessionRequestCount = 0
    @Published private(set) var pendingRequestCount = 0
    @Published private(set) var mascotVisible = false
    @Published private(set) var isRefreshingLocation = false
    @Published private(set) var locationMessage: String?
    @Published private(set) var hasOpenSkyCredentials = false
    @Published private(set) var credentialMessage: String?
    @Published var openSkyClientID = ""
    @Published var openSkyClientSecret = ""

    private let demoProvider: any AircraftProvider = DemoAircraftProvider()
    private let routeProvider = ADSBDBRouteProvider()
    private var liveProvider = OpenSkyProvider()
    private let credentialStore = OpenSkyCredentialStore()
    private let eligibility = EligibilityTracker()
    private let overlay = OverlayCoordinator()
    private let details = AircraftDetailsCoordinator()
    private var watchTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var routeLookupTask: Task<Void, Never>?
    private var routeLookupKey: String?
    private var isFetchingLive = false
    private lazy var locationCoordinator = UserLocationCoordinator()

    init() {
        do {
            if let credentials = try credentialStore.load() {
                liveProvider = OpenSkyProvider(credentials: credentials)
                openSkyClientID = credentials.clientID
                hasOpenSkyCredentials = true
            }
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    private var center: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    func previewMascot() {
        fetchTask = Task { [weak self] in
            guard let self else { return }
            status = .loading
            do {
                let observations = try await demoProvider.nearbyAircraft(
                    center: center,
                    radiusKilometers: radiusKilometers
                )
                let candidates = ProximityEngine().rankedCandidates(
                    observations: observations,
                    around: center,
                    configuration: ProximityConfiguration(radiusKilometers: radiusKilometers),
                    now: .now
                )
                guard let candidate = candidates.first else {
                    status = .noAircraft
                    return
                }
                setNearest(candidate)
                present(candidate)
            } catch {
                status = .providerError(error.localizedDescription)
            }
        }
    }

    func checkLiveSky() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchLive()
        }
    }

    func saveOpenSkyCredentials() {
        let clientID = openSkyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = openSkyClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            credentialMessage = "Enter both the OpenSky client ID and client secret."
            return
        }
        let credentials = OpenSkyCredentials(clientID: clientID, clientSecret: clientSecret)
        do {
            try credentialStore.save(credentials)
            liveProvider = OpenSkyProvider(credentials: credentials)
            openSkyClientSecret = ""
            hasOpenSkyCredentials = true
            remainingCredits = nil
            credentialMessage = "Saved securely in macOS Keychain. Check now to verify it."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    func removeOpenSkyCredentials() {
        do {
            try credentialStore.remove()
            liveProvider = OpenSkyProvider()
            openSkyClientID = ""
            openSkyClientSecret = ""
            hasOpenSkyCredentials = false
            remainingCredits = nil
            credentialMessage = "Using anonymous OpenSky access."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    func pauseForOneHour() {
        presentationState.manualPauseUntil = .now.addingTimeInterval(3_600)
        status = .paused
        overlay.dismiss()
        mascotVisible = false
        details.dismiss()
    }

    func dismissMascot() {
        overlay.dismiss()
        mascotVisible = false
    }

    func refreshMyLocation() {
        guard !isRefreshingLocation else { return }
        isRefreshingLocation = true
        locationMessage = "Finding your current location…"
        locationCoordinator.refresh { [weak self] result in
            guard let self else { return }
            isRefreshingLocation = false
            switch result {
            case .success(let coordinate):
                latitude = coordinate.latitude
                longitude = coordinate.longitude
                locationMessage = "Location updated. Check now to scan this area."
            case .failure(let error):
                locationMessage = error.localizedDescription
            }
        }
    }

    func resume() {
        presentationState.manualPauseUntil = nil
        status = .monitoring
    }

    private func restartWatchTask() {
        watchTask?.cancel()
        watchTask = nil
        guard watchAutomatically else { return }

        let cadence = pollingCadence
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchLive()
                do {
                    try await Task.sleep(for: cadence.interval)
                } catch {
                    return
                }
            }
        }
    }

    private func fetchLive() async {
        guard !isFetchingLive else { return }
        isFetchingLive = true
        pendingRequestCount = 1
        sessionRequestCount += 1
        defer {
            isFetchingLive = false
            pendingRequestCount = 0
        }
        status = .loading
        let queryCenter = center
        let queryRadius = radiusKilometers
        do {
            let result = try await liveProvider.fetchNearbyAircraft(
                center: queryCenter,
                radiusKilometers: queryRadius
            )
            let observations = result.observations
            remainingCredits = result.usage.remainingCredits
            hasOpenSkyCredentials = result.usage.isAuthenticated
            guard !Task.isCancelled else { return }
            let configuration = ProximityConfiguration(
                radiusKilometers: queryRadius,
                cooldown: 30 * 60
            )
            let ranked = ProximityEngine().rankedCandidates(
                observations: observations,
                around: queryCenter,
                configuration: configuration,
                now: .now
            )
            setNearest(ranked.first)
            if let displayedID = details.displayedAircraftID,
               let updated = ranked.first(where: { $0.observation.id == displayedID }) {
                details.updateIfShowing(updated)
            }
            let candidate = await eligibility.nextEligible(
                observations: observations,
                around: queryCenter,
                configuration: configuration
            )
            if let candidate {
                setNearest(candidate)
                present(candidate)
            } else {
                status = ranked.isEmpty ? .noAircraft : .aircraftNearby
            }
        } catch is CancellationError {
            return
        } catch {
            status = .providerError(error.localizedDescription)
        }
    }

    private func present(_ candidate: AircraftCandidate) {
        switch presentationState.overlayDecision() {
        case .allow:
            status = .aircraftNearby
            if soundEnabled {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            mascotVisible = true
            overlay.show(candidate: candidate) { [weak self] in
                self?.details.show(candidate: candidate)
            } onDismiss: { [weak self] in
                self?.mascotVisible = false
            }
        case .suppress(let reason):
            suppressedCount += 1
            status = reason == .manualPause ? .paused : .aircraftNearby
        }
    }

    private func setNearest(_ candidate: AircraftCandidate?) {
        nearest = candidate
        guard let candidate,
              candidate.observation.source != "FlyBy Demo",
              let callsign = candidate.observation.callsign?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callsign.isEmpty
        else {
            routeLookupTask?.cancel()
            routeLookupTask = nil
            routeLookupKey = nil
            nearestRoute = nil
            isLookingUpNearestRoute = false
            return
        }

        let normalized = callsign.uppercased()
        let key = "\(candidate.observation.id):\(normalized)"
        guard routeLookupKey != key else { return }
        routeLookupTask?.cancel()
        routeLookupKey = key
        nearestRoute = nil
        isLookingUpNearestRoute = true
        routeLookupTask = Task { [weak self] in
            guard let self else { return }
            let result = try? await routeProvider.route(for: normalized)
            guard !Task.isCancelled, routeLookupKey == key else { return }
            nearestRoute = result ?? nil
            isLookingUpNearestRoute = false
        }
    }
}

enum AppStatus: Equatable {
    case monitoring
    case loading
    case aircraftNearby
    case noAircraft
    case paused
    case providerError(String)
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MascotBadge(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FlyBy").font(.title3.bold())
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.watchAutomatically {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }
            }

            if let candidate = model.nearest {
                AircraftCard(
                    candidate: candidate,
                    route: model.nearestRoute,
                    isLookingUpRoute: model.isLookingUpNearestRoute
                ) {
                    model.showDetails(candidate)
                }
            } else {
                QuietSkyCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Live watch", systemImage: "scope")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.watchAutomatically.toggle()
                    } label: {
                        Text(model.watchAutomatically ? "ON" : "OFF")
                            .font(.caption.bold())
                            .frame(width: 54, height: 25)
                    }
                    .buttonStyle(FlyByButtonStyle(prominent: model.watchAutomatically))
                    .accessibilityLabel("Live watch")
                    .accessibilityValue(model.watchAutomatically ? "On" : "Off")
                }

                if model.watchAutomatically {
                    HStack(spacing: 6) {
                        ForEach(PollingCadence.allCases) { cadence in
                            Button(cadence.label) { model.pollingCadence = cadence }
                                .buttonStyle(FlyByButtonStyle(prominent: model.pollingCadence == cadence))
                        }
                    }
                    Text("Up to \(model.pollingCadence.maximumDailyRequests) requests/day while FlyBy runs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Off by default—check manually whenever you want.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if model.pendingRequestCount > 0 {
                        ProgressView()
                            .controlSize(.small)
                        Text("1 pending")
                    } else if let remaining = model.remainingCredits {
                        Label("\(remaining) credits left", systemImage: "gauge.with.dots.needle.33percent")
                    } else {
                        Label("Balance after next check", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    Spacer()
                    Text("\(model.sessionRequestCount) this session")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(FlyByPalette.card, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tracking radius")
                    Spacer()
                    Text("\(model.radiusKilometers, specifier: "%.0f") km")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.radiusKilometers, in: 2...50, step: 1)
            }

            DisclosureGroup("Location & atmosphere") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Latitude", value: $model.latitude, format: .number.precision(.fractionLength(4)))
                        TextField("Longitude", value: $model.longitude, format: .number.precision(.fractionLength(4)))
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        model.refreshMyLocation()
                    } label: {
                        Label(
                            model.isRefreshingLocation ? "Locating…" : "Refresh My Location",
                            systemImage: "location.circle"
                        )
                    }
                    .buttonStyle(FlyByButtonStyle())
                    .disabled(model.isRefreshingLocation)
                    if let message = model.locationMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.soundEnabled.toggle()
                    } label: {
                        Label("Pass-by sound \(model.soundEnabled ? "on" : "off")", systemImage: model.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .buttonStyle(FlyByButtonStyle(prominent: model.soundEnabled))
                    Text("Coordinates stay in memory and are sent only in OpenSky area queries.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    if model.hasOpenSkyCredentials {
                        Label("Authenticated OpenSky access", systemImage: "checkmark.shield.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    TextField("OpenSky client ID", text: $model.openSkyClientID)
                    SecureField(
                        model.hasOpenSkyCredentials ? "Enter a new client secret to replace" : "OpenSky client secret",
                        text: $model.openSkyClientSecret
                    )
                    HStack {
                        Button("Save to Keychain") { model.saveOpenSkyCredentials() }
                            .buttonStyle(FlyByButtonStyle(prominent: true))
                        if model.hasOpenSkyCredentials {
                            Button("Use anonymous") { model.removeOpenSkyCredentials() }
                                .buttonStyle(FlyByButtonStyle())
                        }
                        Spacer()
                        if let accountURL = URL(string: "https://opensky-network.org/my-opensky/account") {
                            Link("Create API client", destination: accountURL)
                        }
                    }
                    if let message = model.credentialMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("OpenSky uses OAuth client credentials—not a single API key. Standard, feeder, and licensed accounts are supported.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)
            } label: {
                HStack {
                    Label("OpenSky account", systemImage: "key.horizontal")
                    Spacer()
                    Text(model.hasOpenSkyCredentials ? "Connected" : "Anonymous")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Check now", systemImage: "location.north.circle.fill") { model.checkLiveSky() }
                    .buttonStyle(FlyByButtonStyle(prominent: true))
                Button("Preview mascot") { model.previewMascot() }
                    .buttonStyle(FlyByButtonStyle())
                Spacer()
            }

            Divider()

            HStack {
                if model.mascotVisible {
                    Button("Hide mascot", systemImage: "xmark.circle") {
                        model.dismissMascot()
                    }
                    .buttonStyle(FlyByButtonStyle())
                }
                if case .paused = model.status {
                    Button("Resume overlays") { model.resume() }
                        .buttonStyle(FlyByButtonStyle())
                } else {
                    Button("Pause 1 hour") { model.pauseForOneHour() }
                        .buttonStyle(FlyByButtonStyle())
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(FlyByButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(FlyByPalette.background)
        .preferredColorScheme(.dark)
    }

    private var statusText: String {
        switch model.status {
        case .monitoring: model.watchAutomatically ? "Watching nearby airspace" : "Ready when you are"
        case .loading: "Scanning nearby airspace…"
        case .aircraftNearby: "Aircraft nearby"
        case .noAircraft: "The nearby sky is quiet"
        case .paused: "Overlays paused"
        case .providerError(let message): message
        }
    }
}

private extension AppModel {
    func showDetails(_ candidate: AircraftCandidate) {
        details.show(candidate: candidate, initialRoute: nearestRoute)
    }
}

private struct QuietSkyCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.moon.fill")
                .font(.system(size: 30))
                .foregroundStyle(.cyan, .indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text("Clear airspace").font(.headline)
                Text("Check now, or switch on Live watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(FlyByPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AircraftCard: View {
    let candidate: AircraftCandidate
    let route: FlightRoute?
    let isLookingUpRoute: Bool
    let openDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.observation.displayName).font(.headline)
                    Text(candidate.observation.category ?? "Aircraft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "airplane.circle.fill").foregroundStyle(.cyan)
            }
            Divider()
            HStack(spacing: 20) {
                metric("DISTANCE", String(format: "%.1f km", candidate.distanceKilometers))
                metric("CLOSEST", String(format: "%.1f km", candidate.predictedClosestApproachKilometers))
                if let altitude = candidate.observation.altitudeMeters {
                    metric("ALTITUDE", String(format: "%.0f m", altitude))
                }
            }
            routeSummary
            Text(candidate.observation.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("View flight details & map", systemImage: "arrow.up.right") {
                openDetails()
            }
            .buttonStyle(FlyByButtonStyle(prominent: true))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(FlyByPalette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var routeSummary: some View {
        if let route {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(route.origin.code ?? "N/A")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.cyan)
                    Text(route.destination.code ?? "N/A")
                    Spacer()
                    Text("ADSBDB")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout.bold())
                Text("\(route.origin.name) → \(route.destination.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        } else if isLookingUpRoute {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Looking up route…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("ROUTE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text("N/A").font(.callout.bold())
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.callout.bold()).monospacedDigit()
        }
    }
}

@MainActor
private final class OverlayCoordinator: NSObject {
    private var panel: NSPanel?
    private var animationTask: Task<Void, Never>?
    private var clickAction: (@MainActor () -> Void)?
    private var dismissAction: (@MainActor () -> Void)?
    private var isParked = false

    func show(
        candidate: AircraftCandidate,
        onClick: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        dismiss()
        guard let screen = NSScreen.main else { return }

        let size = NSSize(width: 220, height: 118)
        let frame = screen.visibleFrame
        let fliesRight = (candidate.observation.trackDegrees ?? 90) < 180
        let startVisible = size.width * 0.12
        let parkedVisible = size.width * 0.52
        let startX = fliesRight ? frame.minX - size.width + startVisible : frame.maxX - startVisible
        let endX = fliesRight ? frame.maxX - parkedVisible : frame.minX - size.width + parkedVisible
        let y = frame.minY + frame.height * 0.68

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: y, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        clickAction = onClick
        dismissAction = onDismiss
        installContent(FlyingMascot(fliesRight: fliesRight), in: panel)
        panel.orderFrontRegardless()
        self.panel = panel

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            park(panel: panel, in: frame, arrivedAtRight: fliesRight, flightY: y)
        } else {
            animate(
                panel: panel,
                from: startX,
                to: endX,
                y: y,
                screenFrame: frame,
                arrivedAtRight: fliesRight,
                duration: 9
            )
        }
    }

    func dismiss() {
        animationTask?.cancel()
        animationTask = nil
        panel?.orderOut(nil)
        panel = nil
        clickAction = nil
        dismissAction = nil
        isParked = false
    }

    private func animate(
        panel: NSPanel,
        from startX: CGFloat,
        to endX: CGFloat,
        y: CGFloat,
        screenFrame: NSRect,
        arrivedAtRight: Bool,
        duration: TimeInterval
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        animationTask = Task { @MainActor [weak self, weak panel] in
            while !Task.isCancelled {
                guard let panel, panel.isVisible else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration)
                let easedProgress = 0.5 - cos(.pi * progress) / 2
                panel.setFrameOrigin(NSPoint(x: startX + (endX - startX) * easedProgress, y: y))
                if progress >= 1 {
                    self?.animationTask = nil
                    self?.park(
                        panel: panel,
                        in: screenFrame,
                        arrivedAtRight: arrivedAtRight,
                        flightY: y
                    )
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
        }
    }

    private func park(panel: NSPanel, in screenFrame: NSRect, arrivedAtRight: Bool, flightY: CGFloat) {
        let size = NSSize(width: 176, height: 60)
        let inset: CGFloat = 10
        let x = arrivedAtRight
            ? screenFrame.maxX - size.width - inset
            : screenFrame.minX + inset
        let y = min(
            screenFrame.maxY - size.height - inset,
            max(screenFrame.minY + inset, flightY + 21)
        )
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        isParked = true
        installContent(ParkedMascot(fliesRight: !arrivedAtRight), in: panel)
    }

    private func installContent<Content: View>(_ content: Content, in panel: NSPanel) {
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]

        // SwiftUI content in a non-activating panel may reject the first click
        // while another app is active. This transparent native layer sits above
        // the artwork and deliberately owns the entire panel hit target.
        let clickCapture = MascotClickCaptureView { [weak self] point in
            guard let self else { return }
            if isParked && point.x >= container.bounds.width - 34 {
                dismissAction?()
                dismiss()
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            clickAction?()
        }
        clickCapture.frame = container.bounds
        clickCapture.autoresizingMask = [.width, .height]

        container.addSubview(hostingView)
        container.addSubview(clickCapture)
        panel.contentView = container
    }
}

@MainActor
private final class MascotClickCaptureView: NSView {
    private let action: @MainActor (CGPoint) -> Void

    init(action: @escaping @MainActor (CGPoint) -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        action(convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct FlyingMascot: View {
    let fliesRight: Bool
    @State private var hovering = false

    var body: some View {
        AircraftMascotView(fliesRight: fliesRight)
            .padding(8)
            .offset(y: hovering ? -3 : 3)
            .animation(
                .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: hovering
            )
            .contentShape(Rectangle())
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            hovering = true
        }
        .accessibilityLabel("Nearby aircraft")
    }
}

private struct ParkedMascot: View {
    let fliesRight: Bool

    var body: some View {
        HStack(spacing: 6) {
            AircraftMascotView(fliesRight: fliesRight, showsContrail: false)
                .frame(width: 48, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("FLYBY")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.cyan)
                Text("Details ↗")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 2)
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 9)
        .frame(width: 170, height: 52)
        .background(FlyByPalette.background, in: Capsule())
        .overlay(Capsule().stroke(.cyan.opacity(0.85), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .frame(width: 176, height: 60)
        .contentShape(Rectangle())
        .accessibilityLabel("Open aircraft details and map")
        .accessibilityAddTraits(.isButton)
    }
}

private enum FlyByPalette {
    static let background = Color(red: 0.085, green: 0.095, blue: 0.12)
    static let card = Color(red: 0.15, green: 0.16, blue: 0.19)
    static let accent = Color(red: 0.27, green: 0.83, blue: 0.94)
}

private struct FlyByButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? FlyByPalette.background : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                prominent ? FlyByPalette.accent : Color(red: 0.22, green: 0.24, blue: 0.28),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
