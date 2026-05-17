import SwiftUI

@main
struct PulseTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup("PulseType", id: "control-center") {
            ControlCenterRootView(model: model)
        }

        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusView(sessionStore: model.sessionStore)
        }
    }
}

private struct ControlCenterRootView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsView(model: model)
            .frame(minWidth: 760, minHeight: 560)
            .onAppear {
                model.registerControlCenterWindowOpener {
                    openWindow(id: "control-center")
                }
            }
    }
}
