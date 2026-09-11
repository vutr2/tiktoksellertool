//
//  CaptureView.swift
//  ListingForge
//
//  Placeholder for the guided camera flow (§4.2 / §10). Implemented in M3.
//

import SwiftUI

struct CaptureView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Capture coming soon",
                systemImage: "camera",
                description: Text("Guided product capture arrives in a later milestone.")
            )
            .navigationTitle("Capture")
        }
    }
}
