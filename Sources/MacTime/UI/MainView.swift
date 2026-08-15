import SwiftUI

struct MainView: View {
    let store: Store
    @State private var tab: Tab = .day

    enum Tab: String, CaseIterable {
        case day = "Day"
        case statistics = "Statistics"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .day:
                DayView(store: store)
            case .statistics:
                StatsView(store: store)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}
