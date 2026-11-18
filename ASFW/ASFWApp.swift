//
//  ASFWApp.swift
//  ASFW
//
//  Created by Alexander Shabelnikov on 21.09.2025.
//

import SwiftUI

/// Explicit test-plan opt-in: hosted unit tests must not discover or control
/// the user's installed driver, or start the app's persisted MCP server.
enum ASFWTestRuntime {
    nonisolated static var hardwareFree: Bool {
        ProcessInfo.processInfo.environment["ASFW_HARDWARE_FREE_TESTS"] == "1"
    }
}

@main
struct ASFWApp: App {
    var body: some Scene {
        WindowGroup {
            if ASFWTestRuntime.hardwareFree {
                EmptyView()
            } else {
                ModernContentView()
            }
        }
        .defaultSize(width: 1440, height: 900)
    }
}
