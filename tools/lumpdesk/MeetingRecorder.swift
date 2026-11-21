// MeetingRecorder.swift: zero-bot dual-track meeting recorder for LumpDesk.
// Captures:
//   1. Microphone ("You") via AVCaptureSession -> 20s rotating WAV chunks
//   2. System audio ("Others") via macOS ScreenCaptureKit -> 20s rotating WAV chunks
// Posts chunks to voice_worker.py (:47824/meeting/chunk?speaker=You|Others).

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SystemAudioTap: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.deskbuddy.lumpdesk.sysaudio")
    private var pcmBuffer = Data()
    private let lock = NSLock()
    private var sampleRate: Double = 48000
    private var channels: Int = 2
    private var isFloat = true
    private var bitsPerChannel = 32
    var onFlushChunk: ((Data) -> Void)?

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1

            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await s.startCapture()
            self.stream = s
            NSLog("LumpDesk: ScreenCaptureKit system audio capture started")
        } catch {
            NSLog("LumpDesk: System audio capture unavailable (grant Screen & System Audio Recording permission): \(error)")
        }
    }

    func stop() {
        let s = stream
        stream = nil
        if let s = s {
            Task { try? await s.stopCapture() }
        }
        flush()
    }

    func flush() {
        lock.lock()
        let raw = pcmBuffer
        pcmBuffer = Data()
        let sr = Int(sampleRate)
        let ch = channels
        let flt = isFloat
        let bits = bitsPerChannel
        lock.unlock()

        guard raw.count > 4000 else { return }
        // Convert Float32 PCM to Int16 WAV if needed so mlx-whisper reads it cleanly
        var int16Data = Data()
        if flt && bits == 32 {
            let count = raw.count / 4
            int16Data.reserveCapacity(count * 2)
            raw.withUnsafeBytes { ptr in
                let floats = ptr.bindMemory(to: Float32.self)
                for i in 0..<count {
                    let clamped = max(-1.0, min(1.0, floats[i]))
                    var sample = Int16(clamped * 32767.0).littleEndian
                    withUnsafeBytes(of: &sample) { int16Data.append(contentsOf: $0) }
                }
            }
        } else {
            int16Data = raw
        }
        let wav = buildWav(pcm16: int16Data, sampleRate: sr, channels: ch)
        onFlushChunk?(wav)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
            bitsPerChannel = Int(asbd.mBitsPerChannel)
            isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
        guard status == kCMBlockBufferNoErr, let ptr = dataPtr, length > 0 else { return }
        let chunk = Data(bytes: ptr, count: length)
        lock.lock()
        pcmBuffer.append(chunk)
        lock.unlock()
    }

    private func buildWav(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        var out = Data()
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        let dataSize = UInt32(pcm16.count)
        let riffSize = UInt32(36 + pcm16.count)

        out.append("RIFF".data(using: .ascii)!)
        out.append(withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })
        out.append("WAVEfmt ".data(using: .ascii)!)
        out.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        out.append(withUnsafeBytes(of: UInt16(channels).littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        out.append("data".data(using: .ascii)!)
        out.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        out.append(pcm16)
        return out
    }
}

final class MeetingRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var rotateTimer: Timer?
    private var sysTap: AnyObject?
    private var isStopping = false
    private(set) var isActive = false
    private(set) var title = ""
    var autoStartedEndTime: TimeInterval?

    func start(title: String, mic: AVCaptureDevice?, endTime: TimeInterval? = nil) {
        guard !isActive else { return }
        self.isActive = true
        self.isStopping = false
        self.title = title
        self.autoStartedEndTime = endTime

        // Notify voice_worker to create the meeting Markdown file
        if let url = URL(string: "\(VOICE_BASE)/meeting/start") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title])
            URLSession.shared.dataTask(with: req).resume()
        }

        // Start microphone capture
        if let mic = mic {
            let session = AVCaptureSession()
            do {
                let input = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureAudioFileOutput()
                if session.canAddOutput(output) { session.addOutput(output) }
                session.startRunning()
                self.captureSession = session
                self.fileOutput = output
                beginMicChunk()
            } catch {
                NSLog("LumpDesk MeetingRecorder mic error: \(error)")
            }
        }

        // Start system audio capture (macOS 13+)
        if #available(macOS 13.0, *) {
            let tap = SystemAudioTap()
            tap.onFlushChunk = { [weak self] wav in
                self?.uploadChunk(wav, speaker: "Others")
            }
            self.sysTap = tap
            Task { await tap.start() }
        }

        // Rotate chunks every 20 seconds
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.rotateChunks()
        }
    }

    private func beginMicChunk() {
        guard let output = fileOutput, isActive, !isStopping else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lump_mtg_mic_\(UUID().uuidString).m4a")
        output.startRecording(to: tmp, outputFileType: .m4a, recordingDelegate: self)
    }

    private func rotateChunks() {
        guard isActive, !isStopping else { return }
        fileOutput?.stopRecording()
        if #available(macOS 13.0, *), let tap = sysTap as? SystemAudioTap {
            tap.flush()
        }
    }

    func stop() {
        guard isActive else { return }
        isStopping = true
        isActive = false
        autoStartedEndTime = nil
        rotateTimer?.invalidate()
        rotateTimer = nil
        fileOutput?.stopRecording()
        if #available(macOS 13.0, *), let tap = sysTap as? SystemAudioTap {
            tap.stop()
        }
        sysTap = nil

        // Give final chunks ~1.5s to upload before triggering summary
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let url = URL(string: "\(VOICE_BASE)/meeting/stop") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                URLSession.shared.dataTask(with: req).resume()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let data = try? Data(contentsOf: outputFileURL), data.count > 2000 {
            uploadChunk(data, speaker: "You")
        }
        try? FileManager.default.removeItem(at: outputFileURL)

        if isActive && !isStopping {
            beginMicChunk()
        } else {
            captureSession?.stopRunning()
            captureSession = nil
            fileOutput = nil
        }
    }

    private func uploadChunk(_ data: Data, speaker: String) {
        guard let url = URL(string: "\(VOICE_BASE)/meeting/chunk?speaker=\(speaker)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }
}
