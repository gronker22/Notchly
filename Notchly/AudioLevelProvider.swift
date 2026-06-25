//
//  AudioLevelProvider.swift
//  Notchly — Phase 2: Waveform source
//
//  Publishes 5 normalized amplitude bands (0...1) for the waveform.
//
//  Source: SYSTEM OUTPUT only (what's playing — music, video) via ScreenCaptureKit.
//  The microphone is NOT used. If Screen Recording permission is denied the bars
//  simply stay flat — they never listen to the mic.
//
//  Permission:
//   - ScreenCaptureKit → "Screen & System Audio Recording" (TCC prompt on first run).
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import Accelerate
import Combine

@MainActor
final class AudioLevelProvider: NSObject, ObservableObject {

    /// 5 bands, 0...1, smoothed. Drives WaveformView.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)

    private let bandCount = 5
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private var window: [Float]

    // Smoothing (fast attack, slower release) so bars feel lively but not jittery.
    private var smoothed = [Float](repeating: 0, count: 5)

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.notchly.audio.samples")
    private var streamOutput: StreamOutput?

    override init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        super.init()
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Lifecycle

    func start() {
        Task { await startSystemAudio() }
    }

    func stop() {
        Task { try? await stream?.stopCapture() }
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // We only want audio; keep the (mandatory) video plane tiny & slow.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let output = StreamOutput { [weak self] samples in
                self?.audioQueue.async { self?.process(samples) }
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            // No system-audio access → bars stay flat. We never fall back to mic.
        }
    }

    // MARK: - DSP

    private func process(_ rawSamples: [Float]) {
        guard let setup = fftSetup, rawSamples.count >= 64 else { return }

        // Window into a fixed-size, zero-padded buffer.
        var input = [Float](repeating: 0, count: fftSize)
        let n = min(fftSize, rawSamples.count)
        for i in 0..<n { input[i] = rawSamples[i] * window[i] }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBytes { rawBuf in
                    let typed = rawBuf.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(typed.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Log-spaced bands across the usable spectrum (skip DC bin 0).
        let usableBins = fftSize / 2
        var bands = [Float](repeating: 0, count: bandCount)
        let minBin = 1
        for b in 0..<bandCount {
            let lo = binIndex(for: b, of: bandCount, min: minBin, max: usableBins)
            let hi = max(lo + 1, binIndex(for: b + 1, of: bandCount, min: minBin, max: usableBins))
            var sum: Float = 0
            for bin in lo..<hi { sum += magnitudes[bin] }
            bands[b] = sum / Float(hi - lo)
        }

        // Compress (log scale) and normalize to a perceptual 0...1.
        var normalized = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let scaled = log10(1 + bands[b] * 40) / 2.2   // tuned for typical music levels
            normalized[b] = min(1, max(0, scaled))
        }

        // Attack/release smoothing.
        for b in 0..<bandCount {
            let target = normalized[b]
            let coeff: Float = target > smoothed[b] ? 0.6 : 0.18
            smoothed[b] += (target - smoothed[b]) * coeff
        }

        let snapshot = smoothed.map { CGFloat($0) }
        Task { @MainActor in self.levels = snapshot }
    }

    private func binIndex(for band: Int, of count: Int, min: Int, max: Int) -> Int {
        let frac = Double(band) / Double(count)
        let logMin = log2(Double(min))
        let logMax = log2(Double(max))
        let value = pow(2.0, logMin + frac * (logMax - logMin))
        return Swift.min(max - 1, Swift.max(min, Int(value)))
    }
}

// MARK: - SCStream audio output

/// Extracts Float32 PCM from each audio sample buffer and forwards it.
private final class StreamOutput: NSObject, SCStreamOutput {
    private let onSamples: ([Float]) -> Void
    init(onSamples: @escaping ([Float]) -> Void) { self.onSamples = onSamples }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )

        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let first = buffers.first, let data = first.mData else { return }

        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let floats = data.bindMemory(to: Float.self, capacity: count)
        let samples = Array(UnsafeBufferPointer(start: floats, count: count))
        onSamples(samples)
    }
}
