import Combine
import Foundation

enum DesktopSection: String, CaseIterable, Identifiable {
    case home
    case history
    case agent
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .history:
            return "历史"
        case .agent:
            return "Agent"
        case .settings:
            return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "waveform"
        case .history:
            return "clock"
        case .agent:
            return "sparkles"
        case .settings:
            return "gearshape"
        }
    }
}

@MainActor
final class ControlCenterState: ObservableObject {
    @Published var selectedSection: DesktopSection = .home
    @Published var historyFilter: LocalHistoryFilter = .all
    @Published private(set) var homeStatsSnapshot: HistoryLifetimeSnapshot = .zero

    private var cancellables = Set<AnyCancellable>()

    init(localHistoryStore: LocalHistoryStore) {
        homeStatsSnapshot = localHistoryStore.lifetimeStatistics()
        localHistoryStore.$lifetimeSnapshot
            .sink { [weak self] snapshot in
                self?.homeStatsSnapshot = snapshot
            }
            .store(in: &cancellables)
    }
}
