//
//  bilibiliApp.swift
//  bilibili
//
//  Created by 高熙鹏 on 2026/7/1.
//

import SwiftUI

@main
struct bilibiliApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.pink)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
