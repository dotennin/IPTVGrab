import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
  public typealias ContentState = DownloadState

  public struct DownloadState: Codable, Hashable {
    var progress: Double       // 0.0–1.0; ignored when recording
    var speedMbps: Double
    var done: Int              // segments downloaded (VOD) or recorded (live)
    var total: Int             // total segments (0 when unknown / live)
    var status: String         // "downloading" | "recording" | "merging"
    var elapsedSec: Int
  }

  var taskId: String
  var taskName: String
  var isRecording: Bool
}
