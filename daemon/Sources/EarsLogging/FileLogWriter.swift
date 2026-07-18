import EarsCore
import Foundation

/// Appends JSON Lines log records to a file, rotating by size and pruning
/// old rotations by count.
///
/// See `Sources/EarsLogging/README.md` for the exact numbered-suffix
/// rotation scheme and the shape of the `log.rotated` record it emits.
///
/// An `actor` because a daemon will call ``append(_:)`` from multiple
/// concurrent call sites once wired up; the mutable `currentSize` and the
/// file on disk need serialized access, which an actor gives for free
/// without a hand-rolled lock.
public actor FileLogWriter {
  /// Size/count rotation thresholds, named after the `docs/logging.md`
  /// config keys they implement (`rotate_max_bytes`, `rotate_max_files`).
  public struct RotationPolicy: Sendable {
    /// Rotate before a record would push the file past this many bytes.
    public var rotateMaxBytes: Int
    /// Maximum number of files kept at once: the active file plus its
    /// numbered backups (`tool.jsonl`, `tool.jsonl.1`, … `tool.jsonl.<n-1>`).
    /// `1` means no backups — rotation truncates the active file in place.
    public var rotateMaxFiles: Int

    public init(rotateMaxBytes: Int, rotateMaxFiles: Int) {
      precondition(rotateMaxBytes > 0, "rotateMaxBytes must be positive")
      precondition(rotateMaxFiles >= 1, "rotateMaxFiles must be at least 1")
      self.rotateMaxBytes = rotateMaxBytes
      self.rotateMaxFiles = rotateMaxFiles
    }
  }

  enum WriterError: Error {
    case couldNotCreateFile(String)
  }

  private let url: URL
  private let rotation: RotationPolicy
  private let tool: String
  private let subsystem: String
  private let category: String
  private let pid: Int32
  private let clock: any NowProviding
  private let fileManager = FileManager.default
  private var currentSize: Int

  /// Opens (creating if necessary) the log file at `url`, resuming its
  /// current byte size so rotation state survives a process restart.
  public init(
    url: URL,
    rotation: RotationPolicy,
    tool: String,
    subsystem: String,
    category: String,
    pid: Int32,
    clock: some NowProviding
  ) throws {
    self.url = url
    self.rotation = rotation
    self.tool = tool
    self.subsystem = subsystem
    self.category = category
    self.pid = pid
    self.clock = clock

    let directory = url.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    if !fileManager.fileExists(atPath: url.path) {
      guard fileManager.createFile(atPath: url.path, contents: nil) else {
        throw WriterError.couldNotCreateFile(url.path)
      }
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    currentSize = (attributes[.size] as? Int) ?? 0
  }

  /// Appends `record` as one JSON line, rotating first if it would push the
  /// file past `rotation.rotateMaxBytes`.
  public func append(_ record: LogRecord) throws {
    let line = LogRecordJSONEncoder.encode(record) + "\n"
    let bytes = Data(line.utf8)
    if currentSize > 0 && currentSize + bytes.count > rotation.rotateMaxBytes {
      try rotate()
    }
    try appendRaw(bytes)
  }

  private func rotate() throws {
    let sizeBeforeRotation = currentSize
    let base = url.path

    if rotation.rotateMaxFiles <= 1 {
      guard fileManager.createFile(atPath: base, contents: nil) else {
        throw WriterError.couldNotCreateFile(base)
      }
    } else {
      let oldest = "\(base).\(rotation.rotateMaxFiles - 1)"
      if fileManager.fileExists(atPath: oldest) {
        try fileManager.removeItem(atPath: oldest)
      }
      for index in stride(from: rotation.rotateMaxFiles - 2, through: 1, by: -1) {
        let source = "\(base).\(index)"
        guard fileManager.fileExists(atPath: source) else { continue }
        try fileManager.moveItem(atPath: source, toPath: "\(base).\(index + 1)")
      }
      try fileManager.moveItem(atPath: base, toPath: "\(base).1")
      guard fileManager.createFile(atPath: base, contents: nil) else {
        throw WriterError.couldNotCreateFile(base)
      }
    }

    currentSize = 0
    let rotatedRecord = LogRecord(
      ts: clock.now(),
      level: .info,
      tool: tool,
      subsystem: subsystem,
      category: category,
      pid: pid,
      event: "log.rotated",
      fields: [
        LogField("file", .string((base as NSString).lastPathComponent)),
        LogField("bytes", .int(sizeBeforeRotation)),
        LogField("rotate_max_bytes", .int(rotation.rotateMaxBytes)),
        LogField("rotate_max_files", .int(rotation.rotateMaxFiles)),
      ]
    )
    try appendRaw(Data((LogRecordJSONEncoder.encode(rotatedRecord) + "\n").utf8))
  }

  private func appendRaw(_ data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(data)
    currentSize += data.count
  }
}
