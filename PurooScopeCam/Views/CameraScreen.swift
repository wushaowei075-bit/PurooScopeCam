import AVFoundation
import Combine
import SwiftUI
import UIKit

private struct DiagnosticExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var isQualityDialogPresented = false
    @State private var isMagnificationDialogPresented = false
    @State private var focusIndicator: FocusIndicatorState?
    @State private var focusDismissToken = UUID()
    @State private var pinchBaseZoom: CGFloat?
    @State private var compositionMarkerPoint: CGPoint?
    @State private var cropUsage: CGFloat = 0
    @State private var isGyroCalibrated = false
    @State private var vignetteOffset: CGPoint = .zero
    @State private var shutterFlashOpacity: Double = 0
    @State private var diagnosticPrompt = false
    @State private var diagnosticMessage: String?
    @State private var diagnosticExport: DiagnosticExport?

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let layout = CameraLayout(size: proxy.size, landscape: isLandscape)

            ZStack(alignment: .top) {
                Color.black
                    .ignoresSafeArea()

                cameraViewport(
                    size: layout.previewSize,
                    topControlInset: (isLandscape ? 8 : 12) - layout.previewOriginY,
                    bottomControlInset: layout.controlsOverlap
                )
                .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                .offset(y: layout.previewOriginY)

                VStack {
                    Spacer(minLength: 0)
                    ControlPanelView()
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.controlsHeight)
                }
                .frame(height: proxy.size.height)

                if camera.authorizationStatus != .authorized {
                    Color.black.opacity(0.90)
                        .ignoresSafeArea()
                    permissionPanel
                        .frame(maxWidth: 320)
                        .padding(24)
                }
            }
            .clipped()
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .confirmationDialog("记录稳定诊断", isPresented: $diagnosticPrompt, titleVisibility: .visible) {
            Button("开始记录（最多 2 分钟）") {
                StabilizationTraceRecorder.shared.startTimedDiagnostics()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("日志含运动数据和少量低分辨率场景样本，仅保存在本机，不会自动上传。")
        }
        .sheet(item: $diagnosticExport) { item in
            DiagnosticShareView(url: item.url)
        }
        .alert("稳定诊断", isPresented: Binding(get: { diagnosticMessage != nil }, set: { if !$0 { diagnosticMessage = nil } })) {
            Button("好", role: .cancel) { diagnosticMessage = nil }
        } message: {
            Text(diagnosticMessage ?? "")
        }
        .task {
            camera.requestAccessAndConfigure()
            motionMonitor.start()
            synchronizeOrientationWithScene()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation(from: UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation(from: UIDevice.current.orientation)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.requestAccessAndConfigure()
                motionMonitor.start()
            case .background:
                camera.stopSession()
                motionMonitor.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: orientationLocked) { _, locked in
            PurooScopeAppDelegate.orientationMask = locked ? interfaceOrientation.orientationMask : .allButUpsideDown
            activeWindowScene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !locked { updateOrientation(from: UIDevice.current.orientation) }
            UIApplication.shared.isIdleTimerDisabled = camera.status.isRecording
        }
        .confirmationDialog(
            "分辨率与帧率",
            isPresented: $isQualityDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(camera.captureQualityOptions) { option in
                Button(option == camera.activeCaptureQuality ? "✓ \(option.title)" : option.title) {
                    camera.captureQualityPreference = option
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "望远镜光学倍率",
            isPresented: $isMagnificationDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(TelescopeMagnificationOption.presets) { option in
                Button(
                    abs(option.value - camera.telescopeMagnification) < 0.01
                        ? "✓ \(option.title)"
                        : option.title
                ) {
                    camera.setTelescopeMagnification(option.value)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Text("PUROO 普徕")
                    .font(.system(size: 19, weight: .light))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(PurooBrandStyle.gradient)

                if camera.status.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("正在录像")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black.opacity(0.58), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PurooBrandStyle.gradient, lineWidth: 1)
                    .opacity(0.72)
            }
            .contextMenu {
                Button("记录稳定诊断（2 分钟）", systemImage: "waveform.path.ecg") {
                    diagnosticPrompt = true
                }
                Button("结束并导出诊断", systemImage: "square.and.arrow.up") {
                    StabilizationTraceRecorder.shared.finishAndExport { url in
                        if let url { diagnosticExport = DiagnosticExport(url: url) }
                        else { diagnosticMessage = "本次尚未记录诊断。" }
                    }
                }
            }

            Spacer(minLength: 16)

            stabilityControl
        }
        .frame(maxWidth: .infinity)
    }

    private var stabilityDotColor: Color {
        guard camera.isStabilizationEnabled else { return .white.opacity(0.35) }
        if cropUsage >= 0.82 { return .red }
        switch motionMonitor.displaySample.band {
        case .stable:
            return Color(red: 0.12, green: 0.92, blue: 0.44)
        case .warning:
            return PurooBrandStyle.yellow
        case .heavy:
            return .orange
        case .unavailable:
            return .white.opacity(0.55)
        }
    }

    private var stabilityControl: some View {
        HStack(spacing: 6) {
            Button {
                camera.cycleStabilizationMode()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(stabilityDotColor)
                        .frame(width: 6, height: 6)

                    Text(camera.isStabilizationEnabled ? camera.stabilizationPreference.title : "稳定")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.leading, 4)
            }
            .buttonStyle(.plain)

            Button {
                camera.setStabilizationEnabled(!camera.isStabilizationEnabled)
            } label: {
                ZStack {
                    Capsule()
                        .fill(
                            camera.isStabilizationEnabled
                                ? Color(red: 0.08, green: 0.82, blue: 0.34)
                                : Color.white.opacity(0.20)
                        )

                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                        .offset(x: camera.isStabilizationEnabled ? 10 : -10)
                }
                .frame(width: 44, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 0.8)
        }
        .contentShape(Capsule())
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: camera.isStabilizationEnabled)
        .disabled(camera.status.isCapturingPhoto || camera.status.isCapturingBurst || camera.status.isFinishingRecording)
        .accessibilityLabel("稳定")
        .accessibilityValue(camera.isStabilizationEnabled ? "已开启" : "已关闭")
    }

    private var alignmentGuideText: String? {
        guard camera.isStabilizationEnabled, hypot(vignetteOffset.x, vignetteOffset.y) >= 0.16 else {
            return nil
        }
        let horizontal = vignetteOffset.x > 0.10 ? "左" : (vignetteOffset.x < -0.10 ? "右" : "")
        let vertical = vignetteOffset.y > 0.10 ? "上" : (vignetteOffset.y < -0.10 ? "下" : "")
        let direction = horizontal + vertical
        guard !direction.isEmpty else { return nil }
        return "目镜偏心 · 请向\(direction)微调夹具"
    }

    private func cameraViewport(
        size: CGSize,
        topControlInset: CGFloat,
        bottomControlInset: CGFloat
    ) -> some View {
        ZStack {
            CameraPreviewView(
                camera: camera,
                motionMonitor: motionMonitor,
                stabilizationPreference: camera.stabilizationPreference,
                isStabilizationEnabled: camera.isStabilizationEnabled,
                opticalMagnification: camera.telescopeMagnification,
                displayZoomFactor: camera.zoomFactor,
                systemStabilizationModeName: camera.status.activePreviewStabilizationMode.scopeDisplayName,
                onTelemetryUpdate: { usage, calibrated, vigOffset in
                    self.cropUsage = usage
                    self.isGyroCalibrated = calibrated
                    self.vignetteOffset = vigOffset
                }
            )

            if camera.reticleMode != .off {
                ScopeReticleOverlayView(
                    mode: camera.reticleMode,
                    rollRadians: motionMonitor.displaySample.roll,
                    pitchRadians: motionMonitor.displaySample.pitch
                )
                .allowsHitTesting(false)
            }

            if let lockedPoint = compositionMarkerPoint {
                CompositionMarkerView()
                    .frame(width: 78, height: 78)
                    .position(lockedPoint)
                    .allowsHitTesting(false)
            }

            if shutterFlashOpacity > 0.001 {
                Color.white
                    .opacity(shutterFlashOpacity)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            toggleCompositionMarker(at: value.location, in: size)
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 1)
                        .onEnded { value in
                            focus(at: value.location, in: size)
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.48)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onEnded { value in
                            if case .second(true, let drag?) = value {
                                lockFocusAndExposure(at: drag.location, in: size)
                            }
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            let base = pinchBaseZoom ?? camera.zoomFactor
                            if pinchBaseZoom == nil {
                                pinchBaseZoom = base
                            }
                            let minZoom: CGFloat = camera.isStabilizationEnabled ? 1.5 : 1.0
                            let target = min(max(base * scale, minZoom), StabilizationTuning.maximumDisplayZoom)
                            camera.setDisplayedZoomFactor(target)
                        }
                        .onEnded { _ in
                            pinchBaseZoom = nil
                        }
                )

            VStack(spacing: 8) {
                previewTopControls

                if camera.focusLocked || camera.exposureLocked {
                    Button {
                        compositionMarkerPoint = nil
                        camera.unlockFocusAndExposure()
                    } label: {
                        Label(
                            "AE/AF 已锁定 · 点击解锁",
                            systemImage: "lock.fill"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .foregroundStyle(.black)
                        .background(PurooBrandStyle.yellow, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if let guide = alignmentGuideText {
                    statusCapsule(text: guide, systemImage: "scope")
                }

                Spacer(minLength: 0)

                if let message = camera.status.errorMessage ?? camera.status.lastMessage {
                    statusCapsule(text: message, systemImage: "exclamationmark.circle.fill")
                }

                if camera.pendingMediaCount > 0 {
                    Button {
                        camera.retryPendingMedia()
                    } label: {
                        Label("重新保存 \(camera.pendingMediaCount) 项", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .regular))
                            .padding(10)
                            .background(.black.opacity(0.7), in: Capsule())
                    }
                    .disabled(camera.status.isSaving || camera.status.isCapturingBurst)
                }

                if camera.isTelemetryWatermarkEnabled {
                    TelemetryWatermarkLiveBanner(
                        scopeMagnification: Int(camera.telescopeMagnification.rounded()),
                        digitalZoom: Double(camera.zoomFactor),
                        totalMagnification: Int((camera.telescopeMagnification * Double(camera.zoomFactor)).rounded()),
                        exposureSummary: camera.liveExposureText,
                        qualityTitle: camera.activeCaptureQuality.shortTitle,
                        stabilizationTitle: camera.isStabilizationEnabled ? camera.stabilizationPreference.title : "直通"
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                CameraAdjustmentBar()
                    .disabled(camera.status.isCapturingPhoto || camera.status.isCapturingBurst || camera.status.isFinishingRecording)
            }
            .padding(.top, topControlInset)
            .padding(.horizontal, 12)
            .padding(.bottom, bottomControlInset + 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: camera.isTelemetryWatermarkEnabled)

            if let focusIndicator {
                FocusReticleView(isLocked: camera.focusLocked)
                    .frame(width: 70, height: 70)
                    .position(focusReticlePosition(for: focusIndicator, in: size))
                    .transition(.scale(scale: 1.18).combined(with: .opacity))
                    .allowsHitTesting(false)

                FocusExposureControl(
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    onEditingChanged: handleExposureEditing
                )
                .frame(width: 36, height: 116)
                .position(exposureControlPosition(for: focusIndicator, in: size))
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.18), value: focusIndicator?.id)
        .onChange(of: camera.stillCaptureFlashTrigger) { _, _ in
            shutterFlashOpacity = 0.42
            withAnimation(.easeOut(duration: 0.22)) {
                shutterFlashOpacity = 0
            }
        }
    }

    private var previewTopControls: some View {
        let totalEquivalentZoom = Int((camera.telescopeMagnification * Double(camera.zoomFactor)).rounded())
        return VStack(spacing: 10) {
            brandHeader

            HStack(spacing: 7) {
                Button {
                    isQualityDialogPresented = true
                } label: {
                    Text(qualityBadgeTitle)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(minWidth: 58, minHeight: 34)
                        .padding(.horizontal, 7)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.58), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(PurooBrandStyle.gradient, lineWidth: 1.2)
                        }
                }
                .buttonStyle(.plain)
                .disabled(orientationLocked || camera.captureQualityOptions.count <= 1)
                .accessibilityLabel("分辨率与帧率")

                Button {
                    isMagnificationDialogPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "binoculars")
                            .font(.system(size: 11.5))
                        Text("\(Int(camera.telescopeMagnification.rounded()))×·总\(totalEquivalentZoom)×")
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(PurooBrandStyle.yellow)
                    .background(.black.opacity(0.58), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(PurooBrandStyle.yellow.opacity(0.72), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(orientationLocked)
                .accessibilityLabel("望远镜倍率")

                Button {
                    camera.reticleMode = camera.reticleMode.next
                } label: {
                    Image(systemName: camera.reticleMode == .gridAndLevel ? "squareshape.split.3x3" : "scope")
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(camera.reticleMode == .off ? .white.opacity(0.85) : PurooBrandStyle.yellow)
                        .background(.black.opacity(0.58), in: Circle())
                        .overlay {
                            Circle().stroke(.white.opacity(0.18), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分划与水平仪")

                Button {
                    camera.isTelemetryWatermarkEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 11, weight: .semibold))
                        Text("铭牌")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(
                        camera.isTelemetryWatermarkEnabled
                            ? Color.black
                            : Color(red: 0.96, green: 0.86, blue: 0.48)
                    )
                    .background(
                        camera.isTelemetryWatermarkEnabled
                            ? Color(red: 0.96, green: 0.86, blue: 0.48)
                            : Color.black.opacity(0.58),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                Color(red: 0.96, green: 0.86, blue: 0.48).opacity(camera.isTelemetryWatermarkEnabled ? 0 : 0.45),
                                lineWidth: 0.9
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("光学铭牌水印")

                Spacer(minLength: 4)
            }
        }
    }

    private func statusCapsule(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .regular))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(.black.opacity(0.62), in: Capsule())
    }

    private var qualityBadgeTitle: String {
        let option = camera.activeCaptureQuality
        guard !option.isAutomatic else { return "自动\n画质" }
        let resolution = option.verticalPixels >= 2160 ? "4K" : "\(option.verticalPixels)p"
        return "\(resolution)\n\(option.frameRate)帧"
    }

    private var permissionPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(PurooBrandStyle.gradient)
            Text("需要相机权限")
                .font(.system(size: 17, weight: .regular))
            Text("请在系统设置中开启相机权限，然后返回应用。")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func focus(at location: CGPoint, in previewSize: CGSize) {
        guard previewSize.width > 1, previewSize.height > 1 else { return }
        let normalizedPoint = CGPoint(
            x: min(max(location.x / previewSize.width, 0), 1),
            y: min(max(location.y / previewSize.height, 0), 1)
        )
        camera.focusInPreview(at: normalizedPoint)

        let nextIndicator = FocusIndicatorState(location: location)
        focusIndicator = nextIndicator
        scheduleFocusDismiss(for: nextIndicator, after: 3.2)
    }

    private func lockFocusAndExposure(at location: CGPoint, in previewSize: CGSize) {
        guard previewSize.width > 1, previewSize.height > 1 else { return }
        let normalizedPoint = CGPoint(
            x: min(max(location.x / previewSize.width, 0), 1),
            y: min(max(location.y / previewSize.height, 0), 1)
        )
        camera.lockFocusAndExposureInPreview(at: normalizedPoint)

        let nextIndicator = FocusIndicatorState(location: location)
        focusIndicator = nextIndicator
        scheduleFocusDismiss(for: nextIndicator, after: 5.0)
    }

    private func toggleCompositionMarker(at location: CGPoint, in previewSize: CGSize) {
        guard previewSize.width > 1, previewSize.height > 1 else { return }
        if let existing = compositionMarkerPoint,
           hypot(existing.x - location.x, existing.y - location.y) < 56 {
            withAnimation(.easeOut(duration: 0.16)) {
                compositionMarkerPoint = nil
            }
            return
        }
        let clamped = CGPoint(
            x: min(max(location.x, 44), max(previewSize.width - 44, 44)),
            y: min(max(location.y, 44), max(previewSize.height - 44, 44))
        )
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            compositionMarkerPoint = clamped
        }
        let normalizedPoint = CGPoint(
            x: min(max(location.x / previewSize.width, 0), 1),
            y: min(max(location.y / previewSize.height, 0), 1)
        )
        camera.focusInPreview(at: normalizedPoint)
    }

    private func scheduleFocusDismiss(
        for indicator: FocusIndicatorState,
        after delay: TimeInterval
    ) {
        let token = UUID()
        focusDismissToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard focusDismissToken == token,
                  focusIndicator?.id == indicator.id
            else {
                return
            }
            withAnimation(.easeIn(duration: 0.22)) {
                focusIndicator = nil
            }
        }
    }

    private func handleExposureEditing(_ editing: Bool) {
        guard let focusIndicator else { return }
        if editing {
            focusDismissToken = UUID()
        } else {
            scheduleFocusDismiss(for: focusIndicator, after: 2.4)
        }
    }

    private func focusReticlePosition(
        for indicator: FocusIndicatorState,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(indicator.location.x, 38), max(size.width - 38, 38)),
            y: min(max(indicator.location.y, 38), max(size.height - 38, 38))
        )
    }

    private func exposureControlPosition(
        for indicator: FocusIndicatorState,
        in size: CGSize
    ) -> CGPoint {
        let reticle = focusReticlePosition(for: indicator, in: size)
        let placeOnRight = reticle.x <= size.width - 92
        return CGPoint(
            x: reticle.x + (placeOnRight ? 54 : -54),
            y: min(max(reticle.y, 64), max(size.height - 64, 64))
        )
    }

    private func synchronizeOrientationWithScene() {
        guard let scene = activeWindowScene else { return }
        apply(interfaceOrientation: scene.effectiveGeometry.interfaceOrientation, requestGeometry: false)
    }

    private func updateOrientation(from deviceOrientation: UIDeviceOrientation) {
        guard !orientationLocked else { return }
        guard let nextOrientation = deviceOrientation.interfaceOrientation else { return }
        apply(interfaceOrientation: nextOrientation, requestGeometry: true)
    }

    private func apply(
        interfaceOrientation nextOrientation: UIInterfaceOrientation,
        requestGeometry: Bool
    ) {
        guard nextOrientation != .unknown else { return }
        interfaceOrientation = nextOrientation
        camera.setVideoOrientation(nextOrientation)

        guard requestGeometry, let scene = activeWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: nextOrientation.orientationMask
        )
        scene.requestGeometryUpdate(preferences) { _ in }
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private var orientationLocked: Bool {
        camera.status.isRecording || camera.status.isFinishingRecording || camera.status.isCapturingPhoto || camera.status.isCapturingBurst
    }
}

private struct FocusIndicatorState: Identifiable {
    let id = UUID()
    let location: CGPoint
}

private struct FocusReticleView: View {
    var isLocked: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(PurooBrandStyle.yellow, lineWidth: isLocked ? 2.0 : 1.5)
                .padding(3)

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(3)
                    .background(PurooBrandStyle.yellow, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
    }
}

private struct CompositionMarkerView: View {
    var onClear: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.8, dash: [6, 3]))
                .foregroundStyle(Color(red: 0.22, green: 0.96, blue: 0.45))

            Circle()
                .fill(Color(red: 0.22, green: 0.96, blue: 0.45))
                .frame(width: 5, height: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("构图位置标记")

            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black, Color(red: 0.22, green: 0.96, blue: 0.45))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
    }
}

private struct ScopeReticleOverlayView: View {
    let mode: ScopeReticleMode
    let rollRadians: Double
    let pitchRadians: Double

    private var isLevel: Bool {
        abs(rollRadians) < 0.025
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let cx = w * 0.5
            let cy = h * 0.5
            let lineColor: Color = isLevel
                ? Color(red: 0.22, green: 0.96, blue: 0.45).opacity(0.85)
                : Color.white.opacity(0.55)

            ZStack {
                if mode == .gridAndLevel {
                    Path { path in
                        for idx in 1...2 {
                            let x = w * CGFloat(idx) / 3.0
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                            let y = h * CGFloat(idx) / 3.0
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.26), lineWidth: 0.8)
                }

                if mode == .crosshairAndLevel {
                    Path { path in
                        let arm: CGFloat = min(w, h) * 0.24
                        let gap: CGFloat = 14
                        // Horizontal arms
                        path.move(to: CGPoint(x: cx - arm, y: cy))
                        path.addLine(to: CGPoint(x: cx - gap, y: cy))
                        path.move(to: CGPoint(x: cx + gap, y: cy))
                        path.addLine(to: CGPoint(x: cx + arm, y: cy))
                        // Vertical arms
                        path.move(to: CGPoint(x: cx, y: cy - arm))
                        path.addLine(to: CGPoint(x: cx, y: cy - gap))
                        path.move(to: CGPoint(x: cx, y: cy + gap))
                        path.addLine(to: CGPoint(x: cx, y: cy + arm))

                        // Mil-dot ticks
                        let step: CGFloat = 22
                        for tick in 1...3 {
                            let offset = gap + CGFloat(tick) * step
                            if offset < arm {
                                path.move(to: CGPoint(x: cx - offset, y: cy - 3.5))
                                path.addLine(to: CGPoint(x: cx - offset, y: cy + 3.5))
                                path.move(to: CGPoint(x: cx + offset, y: cy - 3.5))
                                path.addLine(to: CGPoint(x: cx + offset, y: cy + 3.5))
                                path.move(to: CGPoint(x: cx - 3.5, y: cy - offset))
                                path.addLine(to: CGPoint(x: cx + 3.5, y: cy - offset))
                                path.move(to: CGPoint(x: cx - 3.5, y: cy + offset))
                                path.addLine(to: CGPoint(x: cx + 3.5, y: cy + offset))
                            }
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 1.0)
                }

                // Electronic Horizon Bar
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: cx - 54, y: cy))
                        path.addLine(to: CGPoint(x: cx - 18, y: cy))
                        path.move(to: CGPoint(x: cx + 18, y: cy))
                        path.addLine(to: CGPoint(x: cx + 54, y: cy))
                    }
                    .stroke(lineColor, style: StrokeStyle(lineWidth: isLevel ? 2.0 : 1.3, lineCap: .round))
                    .rotationEffect(.radians(-rollRadians))

                    Circle()
                        .strokeBorder(lineColor, lineWidth: 1.2)
                        .frame(width: 8, height: 8)
                        .position(x: cx, y: cy)
                }
            }
        }
    }
}

private struct FocusExposureControl: View {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false
    @State private var dragStartValue = 0.0

    private let range: ClosedRange<Double> = -3...3

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 14, weight: .regular))

            GeometryReader { proxy in
                let trackHeight = max(proxy.size.height, 1)
                let fraction = min(max((value - range.lowerBound) / rangeLength, 0), 1)
                let knobY = trackHeight * CGFloat(1 - fraction)

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: 2, height: trackHeight)

                    Circle()
                        .fill(PurooBrandStyle.yellow)
                        .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(y: min(max(knobY - (isDragging ? 7 : 5), 0), trackHeight - (isDragging ? 14 : 10)))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                dragStartValue = value
                                onEditingChanged(true)
                            }
                            let delta = Double(-gesture.translation.height / 92) * rangeLength
                            value = min(max(dragStartValue + delta, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
            }
        }
        .padding(.vertical, 4)
        .frame(width: 34, height: 112)
        .foregroundStyle(PurooBrandStyle.yellow)
        .background(.black.opacity(0.36), in: Capsule())
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .accessibilityLabel("调节曝光")
    }

    private var rangeLength: Double {
        range.upperBound - range.lowerBound
    }
}

private struct TelemetryWatermarkLiveBanner: View {
    let scopeMagnification: Int
    let digitalZoom: Double
    let totalMagnification: Int
    let exposureSummary: String
    let qualityTitle: String
    let stabilizationTitle: String

    private let champagneGold = Color(red: 0.96, green: 0.86, blue: 0.48)
    private let coolSilver = Color(red: 0.65, green: 0.69, blue: 0.76)

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    champagneGold.opacity(0.08),
                    champagneGold.opacity(0.85),
                    champagneGold.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)

            HStack(spacing: 10) {
                // Left: Optical Emblem + Brand
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .stroke(champagneGold.opacity(0.88), lineWidth: 1.1)
                            .frame(width: 20, height: 20)

                        Circle()
                            .stroke(champagneGold.opacity(0.42), lineWidth: 0.8)
                            .frame(width: 11, height: 11)

                        Circle()
                            .fill(champagneGold)
                            .frame(width: 3, height: 3)
                    }

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("PUROO PULAI")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(champagneGold)
                            .lineLimit(1)

                        Text("OPTICAL TELEPHOTO")
                            .font(.system(size: 7.5, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(coolSilver)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                // Column 1: Equivalent Magnification
                VStack(alignment: .trailing, spacing: 1.5) {
                    Text("\(totalMagnification)× EQUIV.")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)

                    Text(String(format: "%d×镜 · %.1f×数码", scopeMagnification, digitalZoom))
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(champagneGold.opacity(0.88))
                        .lineLimit(1)
                }

                Rectangle()
                    .fill(champagneGold.opacity(0.26))
                    .frame(width: 1, height: 18)

                // Column 2: Exposure & EIS
                VStack(alignment: .trailing, spacing: 1.5) {
                    Text(exposureSummary)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text("\(qualityTitle) · \(stabilizationTitle)")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(coolSilver)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.045, green: 0.050, blue: 0.065).opacity(0.90),
                    Color(red: 0.075, green: 0.082, blue: 0.108).opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(champagneGold.opacity(0.22), lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

private extension UIDeviceOrientation {
    var interfaceOrientation: UIInterfaceOrientation? {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return nil
        }
    }
}

private extension UIInterfaceOrientation {
    var orientationMask: UIInterfaceOrientationMask {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .allButUpsideDown
        }
    }
}

#Preview {
    CameraScreen()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}
