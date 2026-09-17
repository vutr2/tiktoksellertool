//
//  MainTabView.swift
//  ListingForge
//
//  Shell navigation. Feature screens are placeholders in M1 (foundation only).
//

import SwiftUI

enum MainTab {
    case capture, products, settings
}

struct MainTabView: View {
    @State private var selection: MainTab
    #if DEBUG
    @State private var showDemoSheet: Bool
    #endif

    init() {
        #if DEBUG
        _selection = State(initialValue: DemoMode.initialTab ?? .capture)
        _showDemoSheet = State(initialValue: DemoMode.wantsSheet)
        #else
        _selection = State(initialValue: .capture)
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "camera") }
                .tag(MainTab.capture)
            ProductsView()
                .tabItem { Label("Products", systemImage: "shippingbox") }
                .tag(MainTab.products)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        #if DEBUG
        .sheet(isPresented: $showDemoSheet) { DemoMode.sheetView() }
        #endif
    }
}
