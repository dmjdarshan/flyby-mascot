import AppKit
import FlyByCore
import MapKit
import SwiftUI

@MainActor
final class AircraftDetailsCoordinator {
    private var window: NSWindow?
    private var selectedAircraftID: String?
    private var model: AircraftDetailsModel?

    var displayedAircraftID: String? {
        window?.isVisible == true ? selectedAircraftID : nil
    }

    func show(candidate: AircraftCandidate, initialRoute: FlightRoute? = nil) {
        let model = AircraftDetailsModel(candidate: candidate, initialRoute: initialRoute)
        self.model = model
        let content = AircraftDetailsView(model: model)
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 470, height: 460)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            self.window = window
        }

        window.title = "FlyBy · \(candidate.observation.displayName)"
        selectedAircraftID = candidate.observation.id
        window.contentView = NSHostingView(rootView: content)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        window?.orderOut(nil)
        selectedAircraftID = nil
        model = nil
    }

    func updateIfShowing(_ candidate: AircraftCandidate) {
        guard displayedAircraftID == candidate.observation.id else { return }
        model?.update(candidate: candidate)
    }
}

@MainActor
private final class AircraftDetailsModel: ObservableObject {
    @Published var candidate: AircraftCandidate
    @Published var route: FlightRoute?
    @Published var routeMessage: String? = "N/A"
    @Published var isLookingUpRoute = false
    private let provider = ADSBDBRouteProvider()
    private var lookedUpCallsign: String?

    init(candidate: AircraftCandidate, initialRoute: FlightRoute? = nil) {
        self.candidate = candidate
        route = initialRoute
        if initialRoute != nil {
            lookedUpCallsign = candidate.observation.callsign?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }
    }

    func update(candidate newCandidate: AircraftCandidate) {
        if candidate.observation.callsign != newCandidate.observation.callsign {
            route = nil
            routeMessage = "N/A"
            lookedUpCallsign = nil
        }
        candidate = newCandidate
    }

    func lookupRouteIfNeeded() {
        guard !isLookingUpRoute,
              candidate.observation.source != "FlyBy Demo",
              let callsign = candidate.observation.callsign
        else {
            routeMessage = "N/A"
            return
        }
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, lookedUpCallsign != normalized else { return }
        lookedUpCallsign = normalized
        isLookingUpRoute = true
        routeMessage = nil
        Task {
            do {
                let result = try await provider.route(for: normalized)
                guard candidate.observation.callsign == callsign else {
                    isLookingUpRoute = false
                    return
                }
                route = result
                routeMessage = result == nil ? "N/A" : nil
            } catch {
                route = nil
                routeMessage = "N/A"
            }
            isLookingUpRoute = false
        }
    }
}

private struct AircraftDetailsView: View {
    @ObservedObject var model: AircraftDetailsModel
    @State private var mapPosition: MapCameraPosition

    private var candidate: AircraftCandidate { model.candidate }
    private var aircraft: AircraftObservation { candidate.observation }

    init(model: AircraftDetailsModel) {
        self.model = model
        let location = model.candidate.observation.coordinate
        _mapPosition = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        )))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section("FLIGHT ROUTE", systemImage: "airplane.departure") {
                    if let route = model.route {
                        HStack(alignment: .top, spacing: 10) {
                            routeAirport("FROM", route.origin)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.cyan)
                                .padding(.top, 24)
                            routeAirport("TO", route.destination)
                        }
                        if let airline = route.airline { detail("Airline", airline) }
                        Text("Callsign-based route listed by ADSBDB. It may be outdated or differ from this aircraft's actual flight.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        if model.isLookingUpRoute {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking up exact callsign…")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        } else {
                            detail("From → to", model.routeMessage)
                        }
                        Text("N/A means ADSBDB has no exact route for the transmitted callsign. FlyBy does not infer one from schedules or nearby airports.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Map(position: $mapPosition) {
                    Marker(
                        aircraft.displayName,
                        coordinate: CLLocationCoordinate2D(
                            latitude: aircraft.coordinate.latitude,
                            longitude: aircraft.coordinate.longitude
                        )
                    )
                    .tint(.cyan)
                }
                .mapStyle(.standard)
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Button("Open in Maps", systemImage: "arrow.up.right") { openInMaps() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.1, blue: 0.13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.cyan, in: RoundedRectangle(cornerRadius: 9))
                        .padding(10)
                }

                section("FLY-BY", systemImage: "scope") {
                    HStack(spacing: 8) {
                        metric("NOW", format(candidate.distanceKilometers, "km"))
                        metric("CLOSEST", format(candidate.predictedClosestApproachKilometers, "km"))
                        metric("IN", candidate.secondsUntilClosestApproach > 1
                               ? Duration.seconds(candidate.secondsUntilClosestApproach)
                                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
                               : "Now")
                    }
                    Text("Closest approach is a short-range estimate from the last reported position and track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("MOVEMENT", systemImage: "location.north.line.fill") {
                    detail("Ground speed", aircraft.groundSpeedMetersPerSecond.map { String(format: "%.0f km/h", $0 * 3.6) })
                    detail("True track", aircraft.trackDegrees.map { String(format: "%.0f°", $0) })
                    detail("Vertical rate", aircraft.verticalRateMetersPerSecond.map(verticalRate))
                    detail("On ground", aircraft.isOnGround ? "Yes" : "No")
                }

                section("AIRCRAFT & SIGNAL", systemImage: "airplane") {
                    detail("Callsign", aircraft.callsign)
                    detail("ICAO 24-bit ID", aircraft.id.uppercased())
                    detail("Category", aircraft.category)
                    detail("ICAO country (inferred)", aircraft.originCountry)
                    detail("Squawk", aircraft.squawk)
                    detail("Position source", aircraft.positionSource)
                    detail("Special purpose indicator", aircraft.specialPurposeIndicator.map { $0 ? "Active" : "Inactive" })
                }

                section("POSITION & ALTITUDE", systemImage: "location") {
                    detail("Latitude", String(format: "%.5f°", aircraft.coordinate.latitude))
                    detail("Longitude", String(format: "%.5f°", aircraft.coordinate.longitude))
                    detail("Barometric altitude", aircraft.barometricAltitudeMeters.map { String(format: "%.0f m", $0) })
                    detail("Geometric altitude", aircraft.geometricAltitudeMeters.map { String(format: "%.0f m", $0) })
                    if aircraft.barometricAltitudeMeters == nil && aircraft.geometricAltitudeMeters == nil {
                        detail("Altitude", aircraft.altitudeMeters.map { String(format: "%.0f m", $0) })
                    }
                    detail("Position reported", aircraft.observedAt.formatted(date: .abbreviated, time: .standard))
                    detail("Last contact", aircraft.lastContactAt?.formatted(date: .abbreviated, time: .standard))
                }

                section("DATA COVERAGE", systemImage: "info.circle") {
                    Text(aircraft.source).font(.caption)
                    Text("This is the latest observation, not a continuously moving location. With Live Watch on, this inspector updates when a later poll sees the same aircraft inside your tracking area. It makes no extra requests of its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("OpenSky does not supply origin or destination airports in its live state-vector response. The optional route lookup is a separate callsign match, not confirmation of this flight's itinerary. Registration, exact model, and flight number are not reported here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.105, alpha: 1)))
        .preferredColorScheme(.dark)
        .task(id: aircraft.callsign) {
            model.lookupRouteIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MascotBadge(size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.displayName)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(aircraft.category ?? "Aircraft")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(aircraft.source == "FlyBy Demo" ? "DEMO" : "LAST OBSERVED")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                Text(aircraft.observedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(.cyan)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1)), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeAirport(_ label: String, _ airport: RouteAirport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(airport.code ?? "—").font(.title2.bold()).foregroundStyle(.cyan)
            Text(airport.name).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let municipality = airport.municipality {
                Text(municipality).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "Not reported")
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func format(_ distance: Double, _ unit: String) -> String {
        String(format: "%.1f %@", distance, unit)
    }

    private func verticalRate(_ rate: Double) -> String {
        let movement = rate > 0.1 ? "Climbing" : rate < -0.1 ? "Descending" : "Level"
        return String(format: "%@ · %.1f m/s", movement, abs(rate))
    }

    private func openInMaps() {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(aircraft.coordinate.latitude),\(aircraft.coordinate.longitude)"),
            URLQueryItem(name: "q", value: aircraft.displayName),
        ]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MascotBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.11, green: 0.55, blue: 0.85))
            AircraftMascotView(fliesRight: true, showsContrail: false)
                .frame(width: size * 0.84, height: size * 0.55)
        }
        .frame(width: size, height: size)
    }
}
