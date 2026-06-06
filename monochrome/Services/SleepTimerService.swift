import Foundation
import Combine

// MARK: - SleepTimerService

class SleepTimerService: ObservableObject {
    static let shared = SleepTimerService()

    @Published private(set) var isActive = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var selectedMinutes: Int = 30

    var onTimerFired: (() -> Void)?

    private var timer: Timer?
    private var endDate: Date?

    private init() {}

    // MARK: - Presets

    let presets: [Int] = [5, 10, 15, 20, 30, 45, 60, 90]

    // MARK: - Control

    func start(minutes: Int) {
        cancel()
        selectedMinutes = minutes
        let seconds = minutes * 60
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        remainingSeconds = seconds
        isActive = true

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
        print("[SleepTimer] Started: \(minutes) minutes")
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remainingSeconds = 0
        endDate = nil
        print("[SleepTimer] Cancelled")
    }

    private func tick() {
        guard let end = endDate else { cancel(); return }
        let remaining = max(0, Int(end.timeIntervalSinceNow))
        remainingSeconds = remaining

        if remaining == 0 {
            cancel()
            print("[SleepTimer] Fired")
            DispatchQueue.main.async { self.onTimerFired?() }
        }
    }

    // MARK: - Formatted display

    var remainingFormatted: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
        return "\(s)s"
    }
}

// MARK: - SleepTimerView

import SwiftUI

struct SleepTimerView: View {
    @ObservedObject private var timer = SleepTimerService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Active state header
                if timer.isActive {
                    activeHeader
                }

                List {
                    if timer.isActive {
                        Section {
                            Button(role: .destructive) {
                                timer.cancel()
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Cancel Sleep Timer")
                                }
                            }
                        }
                        .listRowBackground(Theme.card)
                    }

                    Section("Set Timer") {
                        ForEach(timer.presets, id: \.self) { minutes in
                            Button {
                                timer.start(minutes: minutes)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(minuteLabel(minutes))
                                        .foregroundColor(Theme.foreground)
                                    Spacer()
                                    if timer.isActive && timer.selectedMinutes == minutes {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Theme.foreground)
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                }
                            }
                            .listRowBackground(Theme.card)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .background(Theme.background)
            }
            .background(Theme.background)
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Theme.foreground)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var activeHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.fill")
                .font(.system(size: 32))
                .foregroundColor(Theme.foreground)

            Text(timer.remainingFormatted)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.foreground)

            Text("Music will stop after this track ends")
                .font(.system(size: 13))
                .foregroundColor(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Theme.card)
    }

    private func minuteLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) hour\(h > 1 ? "s" : "")" : "\(h)h \(m)m"
    }
}
