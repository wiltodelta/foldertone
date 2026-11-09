#if DEBUG
  import Foundation

  // Synthetic audio is used only by simulator previews and UI tests.
  enum SampleLibrary {
    static func create() throws -> URL {
      let folder = URL.applicationSupportDirectory.appendingPathComponent(
        "Sample music", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (index, name) in ["01 - Slow morning", "02 - A little further", "03 - After the rain"]
        .enumerated()
      {
        let url = folder.appendingPathComponent(name).appendingPathExtension("wav")
        if FileManager.default.fileExists(atPath: url.path) { continue }
        try wave(frequency: Double(220 + index * 110)).write(to: url, options: .atomic)
      }
      return folder
    }

    private static func wave(frequency: Double) -> Data {
      let rate = 22050
      let count = rate * 20
      var data = Data()
      func word<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      data.append(contentsOf: "RIFF".utf8)
      word(UInt32(36 + count * 2))
      data.append(contentsOf: "WAVEfmt ".utf8)
      word(UInt32(16))
      word(UInt16(1))
      word(UInt16(1))
      word(UInt32(rate))
      word(UInt32(rate * 2))
      word(UInt16(2))
      word(UInt16(16))
      data.append(contentsOf: "data".utf8)
      word(UInt32(count * 2))
      for sample in 0..<count {
        let envelope = min(1, Double(sample) / 2205, Double(count - sample) / 2205)
        word(Int16(sin(Double(sample) * 2 * .pi * frequency / Double(rate)) * 600 * envelope))
      }
      return data
    }
  }
#endif
