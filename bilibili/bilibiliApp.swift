//
//  bilibiliApp.swift
//  bilibili
//
//  Created by 高熙鹏 on 2026/7/1.
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowActivationController.activateApplication()
        return true
    }
}

@main
struct bilibiliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.pink)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
