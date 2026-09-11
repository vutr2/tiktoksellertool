//
//  MainTabView.swift
//  ListingForge
//
//  Shell navigation. Feature screens are placeholders in M1 (foundation only).
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "camera") }
            ProductsView()
                .tabItem { Label("Products", systemImage: "shippingbox") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
