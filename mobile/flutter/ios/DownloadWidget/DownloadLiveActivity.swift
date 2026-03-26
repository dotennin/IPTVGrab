import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
      LockScreenView(context: context)
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label {
            Text(context.attributes.taskName)
              .font(.caption)
              .lineLimit(1)
          } icon: {
            Image(
              systemName: context.attributes.isRecording
                ? "record.circle.fill" : "arrow.down.circle.fill"
            )
            .foregroundStyle(context.attributes.isRecording ? .red : .accentColor)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(formatSpeed(context.state.speedMbps))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        DynamicIslandExpandedRegion(.bottom) {
          if context.attributes.isRecording {
            RecordingRow(state: context.state)
          } else {
            ProgressRow(state: context.state)
          }
        }
      } compactLeading: {
        Image(
          systemName: context.attributes.isRecording
            ? "record.circle.fill" : "arrow.down.circle.fill"
        )
        .foregroundStyle(context.attributes.isRecording ? .red : .accentColor)
      } compactTrailing: {
        if context.attributes.isRecording {
          Text("REC")
            .font(.caption2)
            .bold()
            .foregroundStyle(.red)
        } else {
          Text("\(Int(context.state.progress * 100))%")
            .font(.caption2)
            .monospacedDigit()
        }
      } minimal: {
        Image(
          systemName: context.attributes.isRecording
            ? "record.circle.fill" : "arrow.down.circle.fill"
        )
        .foregroundStyle(context.attributes.isRecording ? .red : .accentColor)
      }
    }
  }
}

// MARK: - Lock Screen UI

struct LockScreenView: View {
  let context: ActivityViewContext<DownloadActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(
          systemName: context.attributes.isRecording
            ? "record.circle.fill" : "arrow.down.circle.fill"
        )
        .font(.title3)
        .foregroundStyle(context.attributes.isRecording ? .red : .accentColor)

        Text(context.attributes.taskName)
          .font(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(.white)
          .lineLimit(1)

        Spacer()

        Text(formatSpeed(context.state.speedMbps))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.7))
      }

      if context.attributes.isRecording {
        RecordingRow(state: context.state)
      } else {
        ProgressRow(state: context.state)
      }
    }
    .padding()
  }
}

// MARK: - Shared sub-views

struct ProgressRow: View {
  let state: DownloadActivityAttributes.DownloadState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: state.progress)
        .tint(.accentColor)
      HStack {
        Text(segmentLabel(state))
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.6))
        Spacer()
        Text("\(Int(state.progress * 100))%")
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(.white)
      }
    }
  }

  private func segmentLabel(_ s: DownloadActivityAttributes.DownloadState) -> String {
    s.total > 0 ? "\(s.done) / \(s.total) segs" : "\(s.done) segs"
  }
}

struct RecordingRow: View {
  let state: DownloadActivityAttributes.DownloadState

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
      Text("Recording")
        .font(.caption2)
        .foregroundStyle(.red)
      Text("·")
        .foregroundStyle(.white.opacity(0.4))
      Text("\(state.done) segs")
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.7))
      Spacer()
      Text(formatElapsed(state.elapsedSec))
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.7))
    }
  }
}

// MARK: - Helpers

private func formatSpeed(_ mbps: Double) -> String {
  guard mbps > 0 else { return "" }
  if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
  return String(format: "%.0f KB/s", mbps * 1000)
}

private func formatElapsed(_ sec: Int) -> String {
  let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
  return h > 0
    ? String(format: "%d:%02d:%02d", h, m, s)
    : String(format: "%d:%02d", m, s)
}
