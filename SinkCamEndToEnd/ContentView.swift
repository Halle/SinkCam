//
//  ContentView.swift
//  SinkCamEndToEnd
//
//  Created by Halle Winkler on 05.08.22.
//

import CoreMediaIO
import SwiftUI
import OSLog

// MARK: - ContentView

struct ContentView {
    @ObservedObject var endToEndStreamProvider: EndToEndStreamProvider
}

// MARK: View


extension ContentView: View {
    var body: some View {
        VStack {
            Image(
                self.endToEndStreamProvider
                    .videoExtensionStreamOutputImage ?? self.endToEndStreamProvider
                    .noVideoImage,
                scale: 1.0,
                label: Text("Video Feed")
            )
        }
        .frame(alignment: .top)
        Spacer()
    }
}

// MARK: - ContentView_Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(endToEndStreamProvider: EndToEndStreamProvider())
    }
}

// MARK: - EndToEndStreamProvider

class EndToEndStreamProvider: NSObject, ObservableObject,
    ExtensionDeviceSourceDelegate {
    // MARK: Lifecycle

    // Fake-start the "extension", i.e., the extension code end-to-end but outside the system machinery. Any time this gets complex, it is probably not doing the job and should get a rethink.

    override init() {
        providerSource = ExtensionProviderSource(clientQueue: nil)
        super.init()
        providerSource
            .deviceSource = ExtensionDeviceSource(localizedName: "SinkCam")
        providerSource.deviceSource.extensionDeviceSourceDelegate = self

        NotificationManager
            .postNotification(
                named: NotificationName.startStream
            )
    }

    // MARK: Internal

    // Showing the output video from ExtensionProvider, also should be as simple as possible.

    @Published var videoExtensionStreamOutputImage: CGImage?
    let noVideoImage: CGImage = NSImage(
        systemSymbolName: "video.slash",
        accessibilityDescription: "Image to indicate no video feed available"
    )!.cgImage(forProposedRect: nil, context: nil, hints: nil)! // OK to fail if this isn't available.

    let providerSource: ExtensionProviderSource

    func bufferReceived(_ buffer: CMSampleBuffer) {
        autoreleasepool {
            guard let cvImageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                logger.debug("Couldn't get image buffer, returning.")
                return
            }

            guard let ioSurface = CVPixelBufferGetIOSurface(cvImageBuffer) else {
                logger
                    .debug("Pixel buffer had no IOSurface") // The camera uses IOSurface so we want image to break if there is none.
                return
            }

            let ciImage = CIImage(ioSurface: ioSurface.takeUnretainedValue())
                .oriented(.upMirrored) // Cameras show the user a mirrored image, the other end of the conversation an unmirrored image.

            let context = CIContext(options: nil)

            guard let cgImage = context
                .createCGImage(ciImage, from: ciImage.extent) else { return }

            DispatchQueue.main.async {
                self.videoExtensionStreamOutputImage = cgImage
            }
        }
    }
}
