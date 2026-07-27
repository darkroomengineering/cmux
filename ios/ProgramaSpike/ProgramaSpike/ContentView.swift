import SwiftUI

struct ContentView: View {
    @State private var store = AppStore()

    var body: some View {
        switch store.stage {
        case .pairing:
            PairConnectView(store: store)
        case .workspaces:
            WorkspaceListView(store: store)
        }
    }
}

#Preview {
    ContentView()
}
