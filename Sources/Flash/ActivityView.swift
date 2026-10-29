import SwiftUI

/// The full activity log: everything the panel's five-row "Recent" list
/// has no room for, a week back, grouped by day.
@MainActor
struct ActivityView: View {

    static let windowSize = NSSize(width: 460, height: 520)

    @ObservedObject var activity: ActivityLog

    enum Span: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        var id: Self { self }
    }

    @State private var span: Span = .today

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Button("Open Flash.log") { NSWorkspace.shared.open(Log.url) }
                Button("Clear") { activity.clear() }
                    .disabled(activity.events.isEmpty)
            }
            .padding(12)
            Divider()

            if shown.isEmpty {
                Text(span == .today ? "Nothing yet today." : "Nothing in the last 7 days.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section(day.formatted(.dateTime.weekday(.wide).day().month())) {
                            ForEach(shown.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
                                ActivityRow(event: $0, absoluteTime: true)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    private var shown: [ActivityEvent] {
        switch span {
        case .today: return activity.events.filter { Calendar.current.isDateInToday($0.date) }
        case .week: return activity.events
        }
    }

    /// Start of each day that has events, newest first.
    private var days: [Date] {
        var seen: [Date] = []
        for event in shown {
            let day = Calendar.current.startOfDay(for: event.date)
            if seen.last != day { seen.append(day) }
        }
        return seen
    }
}
