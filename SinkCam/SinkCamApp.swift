//
//  SinkCamApp.swift
//  SinkCam
//
//  Created by Halle Winkler on 10.08.22.
//

import SwiftUI

@main
struct SinkCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""), propertyManager: CustomPropertyManager(), outputImageManager: OutputImageManager(), sinkManager: SinkManager())
                .frame(minWidth: 1280, maxWidth: 1360, minHeight: 900, maxHeight: 940)
        }
    }
}
