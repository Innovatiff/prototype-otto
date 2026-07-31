import SwiftUI

/// Triple-tap overlay: the Step 6 latency ledger for the last turn plus the
/// live barge-in tuning readout. This is the screen you stare at while
/// chasing the 800ms budget on a physical device.
struct DebugOverlayView: View {
    @Bindable var model: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Turn timing")
                    .font(.caption.smallCaps().bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.state.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            timingRows

            Divider()

            bargeSection

            HStack {
                label(
                    "echo cancel",
                    value: (model.debugSnapshot?.voiceProcessingEnabled ?? false) ? "on" : "OFF"
                )
                Spacer()
                label("clip play", value: ms(model.debugSnapshot?.clipPlayLatencyMs))
            }

            HStack {
                label(
                    "endpoint floor",
                    value: model.debugSnapshot.map { String(format: "%.0f dB", $0.endpointThresholdDb) } ?? "—"
                )
                Spacer()
                label("patience", value: ms(model.debugSnapshot?.pauseWindowMs))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 420)
    }

    // MARK: - Timings

    @ViewBuilder
    private var timingRows: some View {
        if let t = model.lastTimings {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                timingRow("endpoint detect", t.endpointMs)
                timingRow("net → first token", t.networkToFirstTokenMs)
                timingRow("token → first clause", t.firstClauseMs)
                timingRow("clause → first audio", t.ttsToFirstAudioMs)
                if let total = t.totalLatencyMs {
                    GridRow {
                        Text("TOTAL (speech → audio)")
                            .font(.caption.bold())
                        Text(ms(total))
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(total <= 800 ? Color.green : Color.red)
                    }
                } else {
                    // Typed turns have no speech end to measure from.
                    timingRow("request → first audio (typed)", t.requestToFirstAudioMs)
                }
            }
        } else {
            Text("No turns yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func timingRow(_ name: String, _ value: Double?) -> GridRow<some View> {
        GridRow {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ms(value))
                .font(.caption.monospaced())
        }
    }

    // MARK: - Barge tuning

    private var bargeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("barge threshold")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f dB", model.bargeThresholdDb))
                    .font(.caption.monospaced())
                Text("· mic \(String(format: "%.0f", model.lastLevelDb)) dB")
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        model.lastLevelDb > model.bargeThresholdDb ? Color.orange : Color.secondary
                    )
            }
            Slider(value: $model.bargeThresholdDb, in: -50 ... -10, step: 1)
        }
    }

    // MARK: - Formatting

    private func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value)
    }

    private func label(_ name: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
        }
    }
}
