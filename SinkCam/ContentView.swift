//
//  ContentView.swift
//  SinkCam
//
//  Created by Halle Winkler on 10.08.22.
//

import AVFoundation
import CoreMediaIO
import OSLog
import SwiftUI
import SystemExtensions

// MARK: - ContentView

let logger = Logger(
    subsystem: Identifiers.orgIDAndProduct.rawValue.lowercased(),
    category: "Application"
)

// MARK: - ContentView

struct ContentView {
    // MARK: Lifecycle

    init(
        systemExtensionRequestManager: SystemExtensionRequestManager,
        propertyManager: CustomPropertyManager,
        outputImageManager: OutputImageManager,
        sinkManager: SinkManager
    ) {
        self.propertyManager = propertyManager
        self.systemExtensionRequestManager = systemExtensionRequestManager
        self.outputImageManager = outputImageManager
        self.sinkManager = sinkManager

        captureSessionManager = CaptureSessionManager(capturingSinkCam: true)

        if captureSessionManager.configured == true, captureSessionManager.captureSession.isRunning == false {
            captureSessionManager.captureSession.startRunning()
            captureSessionManager.videoOutput?.setSampleBufferDelegate(
                outputImageManager,
                queue: captureSessionManager.dataOutputQueue
            )
        } else {
            logger.error("Couldn't start capture session")
        }
    }

    // MARK: Internal

    @ObservedObject var sinkManager: SinkManager
    var captureSessionManager: CaptureSessionManager
    var propertyManager: CustomPropertyManager
    @ObservedObject var systemExtensionRequestManager: SystemExtensionRequestManager
    @ObservedObject var outputImageManager: OutputImageManager
}

// MARK: View

extension ContentView: View {
    var body: some View {
        VStack {
            Image(
                self.outputImageManager
                    .videoExtensionStreamOutputImage ?? self.outputImageManager
                    .noVideoImage,
                scale: 1.0,
                label: Text("Video Feed")
            )
            Button("Install", action: {
                systemExtensionRequestManager.install()
            })
            Button("Uninstall", action: {
                systemExtensionRequestManager.uninstall()
            })

            Text(systemExtensionRequestManager.logText)

            Text(sinkManager.logText)
        }
        .frame(alignment: .top)
        Spacer()
    }
}

// MARK: - ContentView_Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""),
            propertyManager: CustomPropertyManager(),
            outputImageManager: OutputImageManager(), sinkManager: SinkManager()
        )
    }
}

// MARK: - CustomPropertyManager

class CustomPropertyManager: NSObject {
    // MARK: Lifecycle

    // Direct communication with the extension via its published properties

    override init() {
        super.init()
        device = getExtensionDevice(name: CaptureSessionManager.Camera.sinkCam.rawValue)
    }

    // MARK: Internal

    var device: AVCaptureDevice?

    lazy var deviceObjectID: CMIOObjectID? = {
        if let device = device, let deviceObjectID = getCMIODeviceID(fromUUIDString: device.uniqueID) {
            return deviceObjectID
        }
        return nil

    }()

    func getExtensionDevice(name: String) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown],
                                                                mediaType: .video,
                                                                position: .unspecified)
        return discoverySession.devices.first { $0.localizedName == name }
    }

    func propertyExists(
        inDeviceAtID deviceID: CMIODeviceID,
        withSelectorName selectorName: CMIOObjectPropertySelector
    ) -> CMIOObjectPropertyAddress? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selectorName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let exists = CMIOObjectHasProperty(deviceID, &address)
        return exists ? address : nil
    }

    func getCMIODeviceID(fromUUIDString uuidString: String) -> CMIOObjectID? {
        var propertyDataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var cmioObjectPropertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectGetPropertyDataSize(
            CMIOObjectPropertySelector(kCMIOObjectSystemObject),
            &cmioObjectPropertyAddress,
            0,
            nil,
            &propertyDataSize
        )
        let count = Int(propertyDataSize) / MemoryLayout<CMIOObjectID>.size
        var cmioDevices = [CMIOObjectID](repeating: 0, count: count)
        CMIOObjectGetPropertyData(
            CMIOObjectPropertySelector(kCMIOObjectSystemObject),
            &cmioObjectPropertyAddress,
            0,
            nil,
            propertyDataSize,
            &dataUsed,
            &cmioDevices
        )
        for deviceObjectID in cmioDevices {
            cmioObjectPropertyAddress.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            CMIOObjectGetPropertyDataSize(deviceObjectID, &cmioObjectPropertyAddress, 0, nil, &propertyDataSize)
            var deviceName: NSString = ""
            CMIOObjectGetPropertyData(
                deviceObjectID,
                &cmioObjectPropertyAddress,
                0,
                nil,
                propertyDataSize,
                &dataUsed,
                &deviceName
            )
            if String(deviceName) == uuidString {
                return deviceObjectID
            }
        }
        return nil
    }

    func getPropertyValue(withSelectorName selectorName: CMIOObjectPropertySelector, for streamID: CMIOStreamID) -> String? {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selectorName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        if CMIOObjectHasProperty(streamID, &propertyAddress) {
            var propertyDataSize: UInt32 = 0
            CMIOObjectGetPropertyDataSize(streamID, &propertyAddress, 0, nil, &propertyDataSize)
            var name: NSString = ""
            var dataUsed: UInt32 = 0
            CMIOObjectGetPropertyData(streamID, &propertyAddress, 0, nil, propertyDataSize, &dataUsed, &name)
            return name as String
        }
        return nil
    }
}

// MARK: - SystemExtensionRequestManager

class SystemExtensionRequestManager: NSObject, ObservableObject {
    // MARK: Lifecycle

    // Manage install/uninstall of extension

    init(logText: String) {
        super.init()
        self.logText = logText
    }

    // MARK: Internal

    @Published var logText: String = "Installation results here"

    func install() {
        guard let extensionIdentifier = _extensionBundle().bundleIdentifier
        else { return }
        let activationRequest = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        activationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }

    func uninstall() {
        guard let extensionIdentifier = _extensionBundle().bundleIdentifier
        else { return }
        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        deactivationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }

    func _extensionBundle() -> Bundle {
        let extensionsDirectoryURL = URL(
            fileURLWithPath: "Contents/Library/SystemExtensions",
            relativeTo: Bundle.main.bundleURL
        )
        let extensionURLs: [URL]
        do {
            extensionURLs = try FileManager.default.contentsOfDirectory(
                at: extensionsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            fatalError(
                "failed to get the contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)"
            )
        }
        guard let extensionURL = extensionURLs.first else {
            fatalError("failed to find any system extensions")
        }
        guard let extensionBundle = Bundle(url: extensionURL) else {
            fatalError(
                "failed to create a bundle with URL \(extensionURL.absoluteString)"
            )
        }
        return extensionBundle
    }
}

// MARK: OSSystemExtensionRequestDelegate

extension SystemExtensionRequestManager: OSSystemExtensionRequestDelegate {
    public func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        logText =
            "Replacing extension version \(existing.bundleShortVersion) with \(ext.bundleShortVersion)"
        return .replace
    }

    public func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        logText = "Extension needs user approval"
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result.rawValue {
        case 0:
            logText = "\(request) did finish with success, restart container app to communicate with extension"
        case 1:
            logText =
                "\(request) Extension did finish with result success but requires reboot"
        default:
            logText = "\(request) Extension did finish with result \(result)"
        }
    }

    public func request(
        _: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        let errorCode = (error as NSError).code
        var errorString = ""
        switch errorCode {
        case 1:
            errorString = "unknown error"
        case 2:
            errorString = "missing entitlement"
        case 3:
            errorString =
                "Container App for Extension has to be in /Applications to install Extension."
        case 4:
            errorString = "extension not found"
        case 5:
            errorString = "extension missing identifier"
        case 6:
            errorString = "duplicate extension identifer"
        case 7:
            errorString = "unknown extension category"
        case 8:
            errorString = "code signature invalid"
        case 9:
            errorString = "validation failed"
        case 10:
            errorString = "forbidden by system policy"
        case 11:
            errorString = "request canceled"
        case 12:
            errorString = "request superseded"
        case 13:
            errorString = "authorization required"
        default:
            errorString = "unknown code"
        }
        logText = "Extension did fail with error: \(errorString)"
    }
}

// MARK: - OutputImageManager

class OutputImageManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    ObservableObject
{ // Manage receipt of video buffers and conversion into observable CGImage for SwiftUI
    @Published var videoExtensionStreamOutputImage: CGImage?
    let noVideoImage: CGImage = NSImage(
        systemSymbolName: "video.slash",
        accessibilityDescription: "Image to indicate no video feed available"
    )!.cgImage(forProposedRect: nil, context: nil, hints: nil)! // OK to fail if this isn't available.

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        autoreleasepool {
            guard let cvImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                logger.debug("Couldn't get image buffer, returning.")
                return
            }

            guard let ioSurface = CVPixelBufferGetIOSurface(cvImageBuffer) else {
                logger.debug("Pixel buffer had no IOSurface") // This is improbable in an installed extension.
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

// MARK: - SinkManager

class SinkManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: Lifecycle

    override init() {
        logText = ""
        super.init()

        // Create sink
        guard let deviceID = customPropertyManager.deviceObjectID else { return }
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var objectPropertyAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectGetPropertyDataSize(deviceID, &objectPropertyAddress, 0, nil, &dataSize)
        let numberOfStreams = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: numberOfStreams)
        CMIOObjectGetPropertyData(deviceID, &objectPropertyAddress, 0, nil, dataSize, &dataUsed, &streamIDs)

        guard let sourceStream = (streamIDs.first == nil) ? nil : streamIDs.first, // If there's a first stream, make it source
              let sinkStream = (streamIDs.last == streamIDs.first) ? nil : streamIDs.last // If there's a last which isn't also first, make it sink
        else { return }

        // Prepare queue
        let pointerQueue = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        let pointerRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard CMIOStreamCopyBufferQueue(sinkStream, {
            (_: CMIOStreamID, _: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) in
        }, pointerRef, pointerQueue) == 0,
        let queue = pointerQueue.pointee,
        CMIODeviceStartStream(deviceID, sinkStream) == 0 else {
            logger.error("Error: unable to copy queue or find queue pointee or start stream.")
            return
        }

        sinkStreamQueue = queue.takeUnretainedValue()

        // Start capture
        guard captureSessionManager.configured == true, captureSessionManager.captureSession.isRunning == false else {
            logger.error("Error: Couldn't start capture session")
            return
        }
        captureSessionManager.captureSession.startRunning()
        captureSessionManager.videoOutput?.setSampleBufferDelegate(self, queue: captureSessionManager.dataOutputQueue)

        // Check for extension readiness
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [self] _ in
            guard let sinkProperty = customPropertyManager.getPropertyValue(withSelectorName: PropertyName.sink.rawValue.convertedToCMIOObjectPropertySelectorName(), for: sourceStream) else { return }
            sinkIsReady = (sinkProperty == SinkStateOptions.trueState.rawValue ? true : false)
            logText = "\(sinkIsReady ? "Ready" : "Not ready") to stream to sink"
        }
    }

    // MARK: Internal

    @Published var logText: String

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard sinkIsReady, let queue = sinkStreamQueue else { return }
        let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(sampleBuffer).toOpaque())
        CMSimpleQueueEnqueue(queue, element: pointerRef)
    }

    // MARK: Private

    private var sinkIsReady = false
    private var sinkStreamQueue: CMSimpleQueue?
    private let captureSessionManager = CaptureSessionManager(capturingSinkCam: false)
    private let customPropertyManager = CustomPropertyManager()
}
