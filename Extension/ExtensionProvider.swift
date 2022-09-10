// ExtensionProvider.swift
// Halle Winkler 2022

import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

private let customSinkExtensionProperty: CMIOExtensionProperty = .init(rawValue: "4cc_" + PropertyName.sink
    .rawValue + "_glob_0000")
let kWhiteStripeHeight: Int = 10

let logger = Logger(
    subsystem: Identifiers.orgIDAndProduct.rawValue.lowercased(),
    category: "Extension"
)

// MARK: - ExtensionDeviceSourceDelegate

protocol ExtensionDeviceSourceDelegate: NSObject {
    func bufferReceived(_ buffer: CMSampleBuffer)
}

// MARK: - ExtensionDeviceSource

class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // MARK: Lifecycle

    init(localizedName: String) {
        super.init()
        guard let bundleID = Bundle.main.bundleIdentifier else { return } // Supports end-to-end testing app
        if bundleID.contains("EndToEnd") {
            _isExtension = false
        }
        let deviceID = UUID()
        self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: deviceID.uuidString, source: self)

        let dims = CMVideoDimensions(width: Int32(outputWidth), height: Int32(outputHeight))
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription
        )

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dims.width,
            kCVPixelBufferHeightKey: dims.height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

        let videoStreamFormat = CMIOExtensionStreamFormat(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let videoID = UUID()
        let videoSinkID = UUID()

        _streamSource = ExtensionStreamSource(localizedName: "SinkCam.Video", streamID: videoID, streamFormat: videoStreamFormat, device: device)
        _streamSink = ExtensionStreamSink(localizedName: "SinkCam.Video.Sink", streamID: videoSinkID, streamFormat: videoStreamFormat, device: device)

        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add source stream: \(error.localizedDescription)")
        }
        do {
            try device.addStream(_streamSink.stream)
        } catch {
            fatalError("Failed to add sink stream: \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    weak var extensionDeviceSourceDelegate: ExtensionDeviceSourceDelegate?

    var _streamSource: ExtensionStreamSource!

    var _isExtension: Bool = true

    private(set) var device: CMIOExtensionDevice!

    var _streamingSourceCounter: UInt32 = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "SinkCam Model"
        }

        return deviceProperties
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {}

    func startStreamingSource() {
        guard let _ = _bufferPool else {
            return
        }

        _streamingSourceCounter += 1

        _sourceTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _sourceTimerQueue)
        _sourceTimer!.schedule(deadline: .now(), repeating: Double(1 / kFrameRate), leeway: .seconds(0))

        _sourceTimer!.setEventHandler {
            if self._streamingSinkCounter > 0 {
                return
            }
            var err: OSStatus = 0
            let now = CMClockGetTime(CMClockGetHostTimeClock())

            var pixelBuffer: CVPixelBuffer?
            err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
            if err != 0 {
                os_log(.error, "out of pixel buffers \(err)")
            }

            if let pixelBuffer = pixelBuffer {
                CVPixelBufferLockBaseAddress(pixelBuffer, [])

                var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                memset(bufferPtr, 0, rowBytes * height)

                let whiteStripeStartRow = self._whiteStripeStartRow
                if self._whiteStripeIsAscending {
                    self._whiteStripeStartRow = whiteStripeStartRow - 1
                    self._whiteStripeIsAscending = self._whiteStripeStartRow > 0
                } else {
                    self._whiteStripeStartRow = whiteStripeStartRow + 1
                    self._whiteStripeIsAscending = self._whiteStripeStartRow >= (height - kWhiteStripeHeight)
                }
                bufferPtr += rowBytes * Int(whiteStripeStartRow)
                for _ in 0 ..< kWhiteStripeHeight {
                    for _ in 0 ..< width {
                        var white: UInt32 = 0xFFFF_FFFF
                        memcpy(bufferPtr, &white, MemoryLayout.size(ofValue: white))
                        bufferPtr += MemoryLayout.size(ofValue: white)
                    }
                }

                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                var sbuf: CMSampleBuffer!
                var timingInfo = CMSampleTimingInfo()
                timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
                err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
                if err == 0 {
                    if self._isExtension {
                        self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                    } else {
                        self.extensionDeviceSourceDelegate?
                            .bufferReceived(sbuf)
                    }
                } else {
                    logger.error("Error at video time \(timingInfo.presentationTimeStamp.seconds) now \(now.seconds) err \(err)")
                }
            }
        }

        _sourceTimer!.setCancelHandler {}

        _sourceTimer!.resume()
    }

    func stopStreaming() {
        if _streamingSourceCounter > 1 {
            _streamingSourceCounter -= 1
        } else {
            _streamingSourceCounter = 0
            if let timer = _sourceTimer {
                timer.cancel()
                _sourceTimer = nil
            }
        }
    }

    func startStreamingSink(from client: CMIOExtensionClient) {
        guard let _ = _bufferPool else { return }
        _streamingSinkCounter += 1
        _sinkTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _sinkTimerQueue)
        _sinkTimer!.schedule(deadline: .now(), repeating: 1.0 / (Double(kFrameRate) * 3.0), leeway: .milliseconds(10)) // We run this more frequently than the source stream function to allow jitter, early return if there is no buffer

        _sinkTimer!.setEventHandler {
            self._streamSink.stream.consumeSampleBuffer(from: client) { sbuf, seq, _, _, _ in
                guard let sbuf = sbuf else { return }

                let time = CMClockGetTime(CMClockGetHostTimeClock())
                let output: CMIOExtensionScheduledOutput = .init(sequenceNumber: seq, hostTimeInNanoseconds: UInt64(time.seconds * Double(NSEC_PER_SEC)))
                if self._streamingSourceCounter > 0 {
                    self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                }
                self._streamSink.stream.notifyScheduledOutputChanged(output)
            }
        }

        _sinkTimer!.setCancelHandler {}

        _sinkTimer!.resume()
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        startStreamingSink(from: client)
    }

    func stopStreamingSink() {
        if _streamingSinkCounter > 1 {
            _streamingSinkCounter -= 1
        } else {
            _streamingSinkCounter = 0
        }
    }

    // MARK: Private

    private var _streamSink: ExtensionStreamSink!

    private var _streamingSinkCounter: UInt32 = 0

    private var _sourceTimer: DispatchSourceTimer?

    private let _sourceTimerQueue = DispatchQueue(label: "sourceTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))

    private var _sinkTimer: DispatchSourceTimer?

    private let _sinkTimerQueue = DispatchQueue(label: "sinkTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))

    private var _videoDescription: CMFormatDescription!

    private var _bufferPool: CVPixelBufferPool!

    private var _bufferAuxAttributes: NSDictionary!

    private var _whiteStripeStartRow: UInt32 = 0

    private var _whiteStripeIsAscending: Bool = false
}

// MARK: - ExtensionStreamSource

class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    // MARK: Lifecycle

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    // MARK: Internal

    private(set) var stream: CMIOExtensionStream!

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration, customSinkExtensionProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(customSinkExtensionProperty) {
            if let deviceSource = device.source as? ExtensionDeviceSource {
                self.sink = false
                if deviceSource._streamingSourceCounter <= 1 {
                    self.sink = true
                }
            }
            let sinkState: String = self.sink ? SinkStateOptions.trueState.rawValue : SinkStateOptions.falseState.rawValue
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: sinkState as NSString), forProperty: customSinkExtensionProperty)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        // An opportunity to inspect the client info and decide if it should be allowed to start the stream.
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreamingSource()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }

    // MARK: Private

    private var sink: Bool = false

    private let device: CMIOExtensionDevice

    private let _streamFormat: CMIOExtensionStreamFormat
}

// MARK: - ExtensionStreamSink

class ExtensionStreamSink: NSObject, CMIOExtensionStreamSource {
    // MARK: Lifecycle

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    // MARK: Internal

    private(set) var stream: CMIOExtensionStream!

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource, let client = client else {
            fatalError("Unexpected source type \(String(describing: device.source)) or no client.")
        }
        deviceSource.startStreamingSink(client: client)
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreamingSink()
    }

    // MARK: Private

    private let device: CMIOExtensionDevice
    private var client: CMIOExtensionClient?

    private let _streamFormat: CMIOExtensionStreamFormat
}

// MARK: - ExtensionProviderSource

class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    // MARK: Lifecycle

    deinit {
        stopNotificationListeners()
    }

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: CaptureSessionManager.Camera.sinkCam.rawValue)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
        startNotificationListeners()
    }

    // MARK: Internal

    private(set) var provider: CMIOExtensionProvider!

    var deviceSource: ExtensionDeviceSource!

    var availableProperties: Set<CMIOExtensionProperty> {
        // See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
        return [.providerManufacturer]
    }

    func connect(to _: CMIOExtensionClient) throws {}

    func disconnect(from _: CMIOExtensionClient) {}

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "SinkCam Manufacturer"
        }
        return providerProperties
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {
        // Handle settable properties here.
    }

    // MARK: Private

    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    private var notificationListenerStarted = false
}

extension ExtensionProviderSource {
    // Hooks for end-to-end testing to substitute for inability to connect to published service properties
    private func notificationReceived(notificationName: String) {
        if let name = NotificationName(rawValue: notificationName) {
            switch name {
            case .startStream:
                do {
                    try deviceSource._streamSource.startStream()
                } catch {
                    logger.debug("Couldn't start the stream")
                }
            case .stopStream:
                do {
                    try deviceSource._streamSource.stopStream()
                } catch {
                    logger.debug("Couldn't stop the stream")
                }
            }
        }
    }

    private func startNotificationListeners() {
        for notificationName in NotificationName.allCases {
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                { _, observer, name, _, _ in
                    if let observer = observer, let name = name {
                        let extensionProviderSourceSelf = Unmanaged<ExtensionProviderSource>.fromOpaque(observer)
                            .takeUnretainedValue()
                        extensionProviderSourceSelf.notificationReceived(notificationName: name.rawValue as String)
                    }
                },
                notificationName.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func stopNotificationListeners() {
        if notificationListenerStarted {
            CFNotificationCenterRemoveEveryObserver(notificationCenter,
                                                    Unmanaged.passRetained(self)
                                                        .toOpaque())
            notificationListenerStarted = false
        }
    }
}
