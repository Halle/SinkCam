//
// Created by Halle Winkler on Aug/18/22. Copyright © 2022. All rights reserved.
//

import SwiftUI

@main
struct SinkCamEndToEndApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(endToEndStreamProvider: EndToEndStreamProvider())
                .frame(minWidth: 1280, maxWidth: 1360, minHeight: 900, maxHeight: 940)
        }
    }
}
