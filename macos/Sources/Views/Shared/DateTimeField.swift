import SwiftUI

/// A date and a time to pick: a date button opens a month, a time button a list of quarter hours, and a few ready-made
/// moments sit beside them. Days and times before `minimum` can't be picked. (Windows: shared/ui/DateTimeField.tsx)
struct DateTimeField: View {
    @Binding var value: Date
    /// The earliest moment to offer
    var minimum: Date? = nil
    /// The clock for the ready-made moments
    var now: Date = Date()
    @Environment(\.locale) private var locale
    @ViewState private var datePanel = false
    @ViewState private var timePanel = false

    var body: some View {
        HStack(spacing: 6) {
            fieldButton(icon: "calendar", text: value.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)),
                        label: "Choose a date", open: $datePanel)
                .popover(isPresented: $datePanel, arrowEdge: .bottom) {
                    MonthPanel(value: value, minimum: minimum) { day in
                        value = CalendarGrid.with(day: day, from: value); datePanel = false
                    }
                }
            fieldButton(icon: "clock", text: value.formatted(.dateTime.hour().minute().locale(locale)), label: "Choose a time", open: $timePanel)
                .popover(isPresented: $timePanel, arrowEdge: .bottom) {
                    TimePanel(value: value, minimum: minimum) { minutes in
                        value = CalendarGrid.with(minutes: minutes, from: value); timePanel = false
                    }
                }
            HStack(spacing: 4) {
                ForEach(CalendarGrid.presets(now: now), id: \.0) { preset, at in
                    PresetChip(title: title(preset), on: at == value) { value = at }
                        .help(at.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(.leading, 4)
        }
    }

    private func title(_ preset: CalendarGrid.Preset) -> String {
        switch preset {
        case .hour: String(localized: "In 1 hour")
        case .tonight: String(localized: "Tonight")
        case .tomorrow: String(localized: "Tomorrow morning")
        }
    }

    private func fieldButton(icon: String, text: String, label: LocalizedStringKey, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                SymbolIcon(icon).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                Text(verbatim: text).font(.system(size: 13).monospacedDigit())
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open.wrappedValue ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    }
}

/// A ready-made moment: a 24 pt capsule, the selection tint while it is the chosen one
private struct PresetChip: View {
    let title: String
    let on: Bool
    let pick: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: pick) {
            Text(verbatim: title).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on || hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(HostedList.caption))
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(on ? StudioStyle.FileList.selection : hovered ? StudioStyle.FileList.hover : .clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : StudioStyle.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The month: a title between previous and next, the weekday initials, then six weeks of days
private struct MonthPanel: View {
    let value: Date
    let minimum: Date?
    let pick: (Date) -> Void
    @Environment(\.locale) private var locale
    @ViewState private var shown: Date?
    private let calendar = Calendar.current

    var body: some View {
        let month = shown ?? value
        let days = CalendarGrid.month(month, calendar: calendar)
        let first = minimum.map { calendar.startOfDay(for: $0) }
        VStack(spacing: 6) {
            HStack {
                navButton("chevron.left", "Previous month") { shown = calendar.date(byAdding: .month, value: -1, to: month) }
                Spacer()
                Text(verbatim: month.formatted(.dateTime.year().month(.wide).locale(locale))).font(.system(size: 13, weight: .semibold))
                Spacer()
                navButton("chevron.right", "Next month") { shown = calendar.date(byAdding: .month, value: 1, to: month) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7), spacing: 2) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(verbatim: d.date.formatted(.dateTime.weekday(.narrow).locale(locale)))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 22)
                }
                ForEach(days, id: \.self) { d in
                    let disabled = first.map { d.date < $0 } ?? false
                    DayCell(day: d, chosen: calendar.isDate(d.date, inSameDayAs: value), today: calendar.isDateInToday(d.date), disabled: disabled) { pick(d.date) }
                }
            }
        }
        .padding(10)
        .frame(width: 252)
    }

    private func navButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { SymbolIcon(symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(HostedList.caption).accessibilityLabel(label)
    }
}

private struct DayCell: View {
    let day: CalendarGrid.Day
    let chosen: Bool
    let today: Bool
    let disabled: Bool
    let pick: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: pick) {
            Text(verbatim: String(day.day)).font(.system(size: 12, weight: chosen || today ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(today ? AnyShapeStyle(Color.accentColor) : day.inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? StudioStyle.FileList.selection : hovered && !disabled ? StudioStyle.FileList.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovered = $0 }
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Quarter hours, the chosen one in view
private struct TimePanel: View {
    let value: Date
    let minimum: Date?
    let pick: (Int) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let chosen = CalendarGrid.minutes(of: value)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(CalendarGrid.slots(step: 15), id: \.self) { m in
                        let at = CalendarGrid.with(minutes: m, from: value)
                        TimeRow(text: at.formatted(.dateTime.hour().minute().locale(locale)), chosen: m == chosen,
                                disabled: minimum.map { at < $0 } ?? false) { pick(m) }
                            .id(m)
                    }
                }
                .padding(6)
            }
            .frame(width: 150, height: 248)
            .onAppear { proxy.scrollTo((chosen / 15) * 15, anchor: .center) }
        }
    }
}

private struct TimeRow: View {
    let text: String
    let chosen: Bool
    let disabled: Bool
    let pick: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: pick) {
            Text(verbatim: text).font(.system(size: 13, weight: chosen ? .semibold : .regular).monospacedDigit())
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? StudioStyle.FileList.selection : hovered && !disabled ? StudioStyle.FileList.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
