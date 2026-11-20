import Foundation
import NaturalLanguage

/// Recovers tag text written in a legacy code page.
///
/// ID3 text frames declare ISO-8859-1, but taggers wrote whatever code page the system used, and
/// AVFoundation reads such a frame as Latin-1, so Cyrillic, Greek, Hebrew, Arabic, Thai, Japanese,
/// Chinese and Korean tags arrive as Latin-1 gibberish that still holds every original byte.
/// Each candidate code page decodes those bytes, and the reading whose letters look most like
/// real words in its own script wins; the person's preferred languages break ties. Western text
/// stays as it was unless another reading is clearly better.
enum TagText {
  struct Candidate {
    let encoding: String.Encoding
    /// Letters a correct decoding produces.
    let scripts: Set<Script>
    /// Language codes whose legacy text commonly used this code page.
    let languages: Set<String>
    /// Accented Latin letters these languages use; other ones suggest misread bytes.
    let nativeLetters: Set<UInt32>

    init(
      encoding: String.Encoding, scripts: Set<Script>, languages: Set<String>,
      nativeLetters: String = ""
    ) {
      self.encoding = encoding
      self.scripts = scripts
      self.languages = languages
      self.nativeLetters = Set(
        (nativeLetters + nativeLetters.uppercased()).unicodeScalars.map(\.value))
    }
  }

  enum Script: Hashable {
    case latin, cyrillic, greek, hebrew, arabic, thai, han, kana, hangul, other
  }

  static func encoding(_ value: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
  }

  static let western = Candidate(
    encoding: .windowsCP1252, scripts: [.latin],
    languages: [
      "en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "nb", "nn", "no", "fi", "ca",
      "ga", "eu", "gl", "af", "id", "ms",
    ], nativeLetters: "àáâãäåæçèéêëìíîïñòóôõöøùúûüýÿœšžß")

  static let candidates: [Candidate] = [
    western,
    Candidate(
      encoding: .windowsCP1250, scripts: [.latin],
      languages: ["pl", "cs", "sk", "hu", "sl", "hr", "ro", "bs", "sq"],
      nativeLetters: "áäâăąćčďđéëęěíîľłńňóôöőřśšşťúůüűýźżžß"),
    Candidate(
      encoding: .windowsCP1251, scripts: [.cyrillic],
      languages: ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "tg", "mn"]),
    Candidate(
      encoding: encoding(.KOI8_R), scripts: [.cyrillic], languages: ["ru", "uk", "be", "bg"]),
    Candidate(encoding: .windowsCP1253, scripts: [.greek], languages: ["el"]),
    Candidate(
      encoding: .windowsCP1254, scripts: [.latin], languages: ["tr", "az"],
      nativeLetters: "çğıöşüâîû"),
    Candidate(encoding: encoding(.windowsHebrew), scripts: [.hebrew], languages: ["he", "yi"]),
    Candidate(
      encoding: encoding(.windowsArabic), scripts: [.arabic], languages: ["ar", "fa", "ur"]),
    Candidate(
      encoding: encoding(.windowsBalticRim), scripts: [.latin], languages: ["lt", "lv", "et"],
      nativeLetters: "ąčęėįšųūžāēģīķļņõäöü"),
    Candidate(encoding: encoding(.dosThai), scripts: [.thai], languages: ["th"]),
    Candidate(encoding: encoding(.dosJapanese), scripts: [.han, .kana], languages: ["ja"]),
    Candidate(encoding: encoding(.GB_18030_2000), scripts: [.han], languages: ["zh-Hans"]),
    Candidate(encoding: encoding(.dosChineseTrad), scripts: [.han], languages: ["zh-Hant"]),
    Candidate(encoding: encoding(.dosKorean), scripts: [.hangul, .han], languages: ["ko"]),
  ]

  /// Decodes the raw bytes of several fields from one file with a single code page, since a
  /// tagger wrote them all the same way and more text makes the choice more reliable.
  static func decode(_ fields: [Data], languages: [String] = Locale.preferredLanguages) -> [String]
  {
    let nonASCII = fields.filter { $0.contains { $0 >= 0x80 } }
    if nonASCII.isEmpty || nonASCII.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) {
      return fields.map { String(decoding: $0, as: UTF8.self) }
    }
    let preferred = languageCodes(languages)
    var readings: [Reading] = []
    let recognizer = NLLanguageRecognizer()
    for candidate in candidates {
      let strings = fields.map { field in
        // Windows-1252 leaves five bytes undefined; Latin-1, which the tag claims, reads them all.
        String(data: field, encoding: candidate.encoding)
          ?? (candidate.encoding == western.encoding
            ? String(data: field, encoding: .isoLatin1) : nil)
      }
      let decoded = strings.compactMap { $0 }
      guard decoded.count == fields.count else { continue }
      let score = decoded.reduce(0) { $0 + plausibility(of: $1, as: candidate) }
      let letters = Double(
        decoded.reduce(0) { $0 + $1.unicodeScalars.filter { $0.value >= 0x80 }.count })
      let rank = candidate.languages.compactMap { preferred.firstIndex(of: $0) }.min()
      let preference = rank.map { letters * 0.25 / Double($0 + 1) } ?? 0
      // The recognizer judges by letters, so it believes only a reading whose letters all
      // belong to the code page's languages.
      let native = decoded.allSatisfy { usesNativeLetters($0, as: candidate) }
      let likelihood =
        candidate.scripts.isDisjoint(with: [.latin, .cyrillic]) || !native
        ? 0 : languageLikelihood(decoded, in: candidate, using: recognizer)
      readings.append(
        Reading(
          candidate: candidate, strings: decoded, score: score,
          withinScript: score + preference + letters * likelihood, likelihood: likelihood,
          ownLanguage: rank != nil && native))
    }
    guard let original = readings.first(where: { $0.candidate.encoding == western.encoding }) else {
      return fields.map { String(decoding: $0, as: UTF8.self) }
    }
    // A Western reading made only of letters Western languages use is kept against other Latin
    // code pages, unless the recognizer finds it in no Western language and the other reading
    // either in one of its own, as with Hungarian ő read as Portuguese õ, or in the person's own
    // language.
    let originalIsClean = original.strings.allSatisfy {
      plausibility(of: $0, as: western)
        >= Double(
          $0.unicodeScalars.filter { $0.value >= 0x80 && $0.properties.isAlphabetic }.count)
    }
    // Within one alphabet the language recognizer picks the code page, since it tells Polish
    // from Turkish or Russian from misread KOI8-R. Across alphabets it is sure of any text, even
    // misread bytes, so alphabets compete on how word-like their readings are. Either way a
    // reading replaces the Western one only when clearly better, because the tag claims Latin-1.
    var winners: [Reading] = []
    for scripts in Set(readings.map(\.candidate.scripts)) {
      let group = readings.filter { $0.candidate.scripts == scripts }
      guard var winner = group.max(by: { $0.withinScript < $1.withinScript }) else { continue }
      let recognized =
        original.likelihood < 0.5 && (winner.likelihood > 0.5 || winner.ownLanguage)
      if scripts == original.candidate.scripts,
        winner.withinScript < original.withinScript + 1 || (originalIsClean && !recognized)
      {
        winner = original
      }
      winners.append(winner)
    }
    let latin = winners.first { $0.candidate.scripts == original.candidate.scripts } ?? original
    let ranked = winners.sorted { $0.score > $1.score }
    guard let best = ranked.first, best.score >= latin.score + 2 else { return latin.strings }
    // Chinese, Japanese and Korean code pages share byte ranges, so two of them can both read as
    // ordinary characters. Between readings that score almost the same, Foundation's detector,
    // which knows their character frequencies, chooses; for very short text, or when it has no
    // answer, the person's own language does.
    let close = ranked.filter {
      $0.score >= best.score - max(2, abs(best.score) * 0.25) && $0.candidate.scripts.contains(.han)
    }
    guard close.count > 1, best.candidate.scripts.contains(.han) else { return best.strings }
    let own = close.compactMap { reading in
      reading.candidate.languages.compactMap { preferred.firstIndex(of: $0) }.min().map {
        (rank: $0, strings: reading.strings)
      }
    }.min { $0.rank < $1.rank }?.strings
    // A word or two carries too few characters for frequencies to beat the person's language.
    let characters = best.strings.reduce(0) {
      $0 + $1.unicodeScalars.filter { $0.value >= 0x80 }.count
    }
    if characters <= 4, let own { return own }
    var converted: NSString?
    var lossy: ObjCBool = false
    let detected = NSString.stringEncoding(
      for: Data(nonASCII.joined(separator: [0x20])),
      encodingOptions: [
        .suggestedEncodingsKey: close.map { NSNumber(value: $0.candidate.encoding.rawValue) },
        .useOnlySuggestedEncodingsKey: true, .allowLossyKey: false,
      ], convertedString: &converted, usedLossyConversion: &lossy)
    if let match = close.first(where: { $0.candidate.encoding.rawValue == detected }) {
      return match.strings
    }
    return own ?? best.strings
  }

  private struct Reading {
    let candidate: Candidate
    let strings: [String]
    /// How word-like the reading is.
    let score: Double
    /// The score plus a nudge toward the person's languages and how much the language
    /// recognizer believes the reading.
    let withinScript: Double
    /// How likely the recognizer finds the reading to be in the code page's languages.
    let likelihood: Double
    /// The code page belongs to one of the person's languages and the reading uses its letters.
    let ownLanguage: Bool
  }

  /// Repairs the title, artist and album of one file: text AVFoundation read from a legacy ID3
  /// frame as Latin-1, or text an app had misread as Latin-1 before storing it in any format.
  /// Spaces that download sites pad tags with are trimmed after the repair, which reads a
  /// leading space in truncated Cyrillic as Р.
  static func repair(_ fields: [String], languages: [String] = Locale.preferredLanguages)
    -> [String]
  {
    recode(fields, languages: languages).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private static func recode(_ fields: [String], languages: [String]) -> [String] {
    guard fields.contains(where: { $0.unicodeScalars.contains { $0.value >= 0x80 } }) else {
      return untruncate(fields)
    }
    var bytes: [Data] = []
    for field in fields {
      // Only text made of Latin-1 characters can be a misread legacy encoding.
      guard let data = field.data(using: .windowsCP1252) ?? field.data(using: .isoLatin1) else {
        return fields
      }
      bytes.append(data)
    }
    return decode(bytes, languages: languages)
  }

  /// Recovers Cyrillic that a tagger stored as the low byte of each UTF-16 code unit, so
  /// "Что ты" arrives as "'B> BK", lowercase letters as digits, punctuation and capitals, and
  /// capitals А to П as invisible control characters. Russian text in such a file has words with
  /// ";<=>?@" (л to р) among letters or control characters; ASCII text stays as it is.
  /// Р becomes a space and is restored only at the start of a field, where a space is unlikely.
  /// Every field must be ASCII.
  private static func untruncate(_ fields: [String]) -> [String] {
    var evidence = false
    let tokens = fields.map { field in
      let words = field.split(separator: " ", omittingEmptySubsequences: false).map {
        $0.unicodeScalars.map { UInt8($0.value) }
      }
      return words.indices.map { index -> (bytes: [UInt8], reading: String?) in
        let later = words[(index + 1)...]
        let word = words[index]
        guard let reading = truncatedReading(of: word, later: later) else { return (word, nil) }
        let score = plausibility(of: reading, as: cp1251)
        // Control characters and ";<=>?@" are rare inside ASCII words but stand for А to П
        // and л to р, so such a word is Cyrillic even when it has few vowels, as in Тролль.
        // A colon, which stands for к, also separates digits in times.
        let telling = word.contains {
          (0x01...0x1F).contains($0) || (0x3B...0x40).contains($0)
        }
        if score >= 3 && telling { evidence = true }
        return (word, score > 0 || telling ? reading : nil)
      }
    }
    guard evidence else { return fields }
    return tokens.map { words in
      var output = words.map { $0.reading ?? String(decoding: $0.bytes, as: UTF8.self) }
      var converted = words.map { $0.reading != nil }
      // Russian one-letter words: к, о, с, у, я next to a converted word, and а, в, и, which
      // read as digits, between two converted words or letters, as in "Ты и я".
      // A converted one-letter word can let its neighbor convert, so repeat until none does.
      let letters: [UInt8] = [0x3A, 0x3E, 0x41, 0x43, 0x4F]
      let isLetter = { (index: Int) in
        index < words.count && words[index].bytes.count == 1
          && letters.contains(words[index].bytes[0])
      }
      var changed = true
      while changed {
        changed = false
        for (bytes, needsBoth) in [(letters, false), ([0x30, 0x32, 0x38], true)] {
          for (index, word) in words.enumerated()
          where !converted[index] && word.bytes.count == 1 && bytes.contains(word.bytes[0]) {
            let before = index > 0 && (converted[index - 1] || (needsBoth && isLetter(index - 1)))
            let after =
              index + 1 < words.count
              && (converted[index + 1] || (needsBoth && isLetter(index + 1)))
            guard needsBoth ? before && after : before || after else { continue }
            output[index] = String(cyrillic(word.bytes[0]))
            converted[index] = true
            changed = true
          }
        }
      }
      if output.count > 1, output[0].isEmpty, converted[1],
        output[1].first?.isLowercase == true
      {
        output[1] = "Р" + output[1]
        output.removeFirst()
      }
      return output.joined(separator: " ")
    }
  }

  private static let cp1251 = candidates.first { $0.encoding == .windowsCP1251 }!

  /// The Cyrillic letter whose UTF-16 code unit has this low byte.
  private static func cyrillic(_ byte: UInt8) -> Unicode.Scalar {
    Unicode.Scalar(0x400 + UInt32(byte))!
  }

  /// The Cyrillic reading of one word of truncated UTF-16, or nil when the word cannot be one.
  private static func truncatedReading(of word: [UInt8], later: ArraySlice<[UInt8]>) -> String? {
    // Lowercase ASCII and P map to archaic letters; tab, newline and return to rare ones.
    guard
      word.allSatisfy({
        (0x01...0x5F).contains($0) && ![0x09, 0x0A, 0x0D, 0x20, 0x50].contains($0)
      }),
      word.contains(where: {
        (0x01...0x1F).contains($0) || (0x3A...0x4F).contains($0) || (0x51...0x5F).contains($0)
      })
    else { return nil }
    let isPunctuation = { (byte: UInt8) in (0x21...0x2F).contains(byte) }
    var scalars: [Unicode.Scalar] = []
    var previousIsCapital = false
    for (position, byte) in word.enumerated() {
      var letter = true
      if isPunctuation(byte) {
        if position == 0 {
          switch byte {
          // Paired brackets and quotes stay punctuation; Ъ, Ы and Ь never start a word.
          case 0x28: letter = !(word.last == 0x29 || later.contains { $0.last == 0x29 })
          case 0x22: letter = !(word.dropFirst().last == 0x22 || later.contains { $0.last == 0x22 })
          case 0x2A, 0x2B, 0x2C: letter = false
          default: letter = word.count > 1
          }
        } else {
          // Inside a lowercase word the byte is punctuation, inside a capitalized run a capital.
          letter = previousIsCapital
        }
      }
      if letter {
        scalars.append(cyrillic(byte))
        previousIsCapital = byte < 0x30
      } else {
        scalars.append(Unicode.Scalar(byte))
        previousIsCapital = false
      }
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func usesNativeLetters(_ text: String, as candidate: Candidate) -> Bool {
    candidate.nativeLetters.isEmpty
      || text.unicodeScalars.allSatisfy {
        $0.value < 0x80 || !$0.properties.isAlphabetic || candidate.nativeLetters.contains($0.value)
      }
  }

  /// How likely the on-device language recognizer finds the text to be in one of the languages
  /// that wrote this code page; misread bytes rarely look like any of them.
  private static func languageLikelihood(
    _ fields: [String], in candidate: Candidate, using recognizer: NLLanguageRecognizer
  ) -> Double {
    recognizer.reset()
    recognizer.processString(fields.joined(separator: " "))
    return recognizer.languageHypotheses(withMaximum: 5)
      .filter { candidate.languages.contains($0.key.rawValue) }
      .reduce(0) { $0 + $1.value }
  }

  private static func languageCodes(_ languages: [String]) -> [String] {
    languages.map { identifier in
      let locale = Locale(identifier: identifier)
      guard let code = locale.language.languageCode?.identifier else { return identifier }
      if code == "zh" {
        let script = locale.language.script?.identifier
        let region = locale.region?.identifier
        let traditional =
          script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region))
        return traditional ? "zh-Hant" : "zh-Hans"
      }
      return code
    }
  }

  /// Punctuation that real titles use, so it neither helps nor hurts a decoding.
  private static let ordinaryPunctuation = Set(
    "’‘“”„«»–—…·•€°©®™¡¿§×".unicodeScalars.map(\.value))

  /// Latin-1 letters that are rare in real titles but common in misread legacy text.
  private static let rareLatin = Set("ÐðÞþ¤¦¨¯´¸¹²³ª¼½¾µº¬ŔŕŢţĹĺ".unicodeScalars.map(\.value))

  private static let hebrewFinals: Set<UInt32> = [0x05DA, 0x05DD, 0x05DF, 0x05E3, 0x05E5]
  private static let hebrewMedials: Set<UInt32> = [0x05DB, 0x05DE, 0x05E0, 0x05E4, 0x05E6]

  /// Vowels of the alphabets whose words cannot do without them.
  private static let vowels = Set(
    "aeiouyAEIOUYıİæÆøØœŒаеёиоуыэюяіїєўАЕЁИОУЫЭЮЯІЇЄЎαεηιουωάέήίόύώϊϋΑΕΗΙΟΥΩΆΈΉΊΌΎΏ".unicodeScalars
      .map(
        \.value))

  private static func isVowel(_ scalar: Unicode.Scalar) -> Bool {
    if vowels.contains(scalar.value) { return true }
    // Accented Latin vowels decompose to a plain vowel and a mark; Cyrillic й does too but
    // is a consonant.
    guard (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value),
      let base = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first
    else { return false }
    return base != scalar && vowels.contains(base.value)
  }

  private static func plausibility(of text: String, as candidate: Candidate) -> Double {
    var score = 0.0
    for word in text.split(whereSeparator: \.isWhitespace) {
      let before = score
      var families: Set<Script> = []
      var asciiLetters = 0
      var cased: [Bool] = []
      var letters = 0
      var foreignLetters = 0
      var vowelCount = 0
      var cjkLetters = 0
      var previousIsThaiTone = false
      var thaiLetters = 0
      var thaiVowels = 0
      var afterLetter = false
      var marksInRow = 0
      var previousIsCedilla = false
      var previousIsVowel = false
      var greekAccents = 0
      var isFirst = true
      let scalars = Array(word.unicodeScalars)
      for (position, scalar) in scalars.enumerated() {
        let value = scalar.value
        let properties = scalar.properties
        if value < 0x80 {
          if properties.isAlphabetic {
            asciiLetters += 1
            letters += 1
            cased.append(properties.isUppercase)
            if isVowel(scalar) { vowelCount += 1 }
          }
          previousIsThaiTone = false
          afterLetter = properties.isAlphabetic
          marksInRow = 0
          // A cedilla c comes before a vowel in every Western language.
          if previousIsCedilla, properties.isAlphabetic, !isVowel(scalar) { score -= 1 }
          previousIsCedilla = false
          previousIsVowel = isVowel(scalar)
          isFirst = false
          continue
        }
        if properties.generalCategory == .control || properties.generalCategory == .privateUse
          || value == 0xFFFD
        {
          score -= 5
          continue
        }
        let script = self.script(of: scalar)
        let last = position == scalars.count - 1
        // A combining mark needs a letter before it.
        let isMark = properties.generalCategory == .nonspacingMark
        if isMark && !afterLetter { score -= 2 }
        marksInRow = isMark ? marksInRow + 1 : 0
        if marksInRow > 2 { score -= 2 }
        if script == .thai {
          // Thai digits and signs, a tone mark stacked on another, and a leading vowel or mai
          // han-akat with no consonant after it appear only when other bytes are read as Thai.
          let tone = (0x0E48...0x0E4C).contains(value)
          let needsFollower = (0x0E40...0x0E44).contains(value) || value == 0x0E31
          if value >= 0x0E4F || (tone && previousIsThaiTone) || (needsFollower && last) {
            score -= 2
          }
          previousIsThaiTone = tone
          thaiLetters += 1
          if (0x0E30...0x0E3A).contains(value) || (0x0E40...0x0E45).contains(value)
            || value == 0x0E47
          {
            thaiVowels += 1
          }
        } else {
          previousIsThaiTone = false
        }
        if script == .hebrew {
          // Final letter forms end a word and their ordinary forms never do.
          if (hebrewFinals.contains(value) && !last)
            || (hebrewMedials.contains(value) && last && letters > 0)
          {
            score -= 2
          }
        }
        // Arabic nunation marks the end of a word.
        if (0x064B...0x064D).contains(value) && !last { score -= 2 }
        if [0x03CA, 0x03CB, 0x0390, 0x03B0, 0x03AA, 0x03AB].contains(value) { score -= 1 }
        afterLetter = properties.isAlphabetic || script != .other
        previousIsCedilla = value == 0x00E7 || value == 0x00C7
        guard properties.isAlphabetic || script != .other else {
          if !ordinaryPunctuation.contains(value) { score -= 2 }
          continue
        }
        letters += 1
        foreignLetters += 1
        if script != .other { families.insert(script == .kana ? .han : script) }
        if [.han, .kana, .hangul].contains(script) { cjkLetters += 1 }
        if isVowel(scalar) { vowelCount += 1 }
        if properties.changesWhenCaseMapped { cased.append(properties.isUppercase) }
        if !candidate.scripts.contains(script) {
          score -= 2
        } else if script == .han {
          score += isCommon(scalar, for: candidate) ? 2 : 0.5
        } else if script == .hangul {
          score += isCommon(scalar, for: candidate) ? 2 : 0
        } else if script == .kana {
          score += (0xFF61...0xFF9F).contains(value) ? -1 : 2
        } else {
          score += 1
        }
        if script == .latin && rareLatin.contains(value) { score -= 1 }
        if script == .latin, !candidate.nativeLetters.isEmpty,
          !candidate.nativeLetters.contains(value)
        {
          score -= 3
        }
        if script == .greek {
          // Final sigma ends a word and medial sigma never does.
          if (value == 0x03C2 && !last) || (value == 0x03C3 && last) { score -= 2 }
          if (0x03AC...0x03AF).contains(value) || (0x03CC...0x03CE).contains(value)
            || value == 0x0390 || value == 0x03B0
          {
            greekAccents += 1
          }
        }
        if script == .cyrillic, "ЬьЪъЫы".unicodeScalars.contains(scalar),
          isFirst || previousIsVowel
        {
          // Russian never starts a word with these letters or puts them after a vowel.
          score -= 2
        }
        previousIsVowel = isVowel(scalar)
        isFirst = false
      }
      // A word mixes scripts only in misread text, apart from Latin letters inside Chinese,
      // Japanese or Korean names and Hanja among Hangul.
      let mixedWithASCII =
        asciiLetters > 0 && !families.isEmpty
        && (families.isDisjoint(with: [.latin, .han, .hangul])
          || (cjkLetters > 0 && asciiLetters >= cjkLetters))
      if (families.count > 1 && families != [.han, .hangul]) || mixedWithASCII {
        score -= 3 * Double(letters)
      }
      if foreignLetters > 0 && cased.count > 1 && !isOrdinaryCase(cased) {
        score -= 2 * Double(foreignLetters)
      } else if foreignLetters > 1, cased.count == letters, cased.allSatisfy({ $0 }) {
        // Real titles are seldom set in capitals, while misread lowercase bytes of another
        // alphabet often land on capitals, as in KOI8-R.
        score -= Double(foreignLetters) / 4
      }
      if families == [.latin], letters >= 2, foreignLetters * 2 > letters {
        score -= Double(foreignLetters)
      }
      // Monotonic Greek marks the stress of every lowercase word longer than one syllable.
      if families == [.greek], foreignLetters >= 4, greekAccents == 0,
        cased.contains(false)
      {
        score -= Double(foreignLetters) / 2
      } else if families == [.greek], greekAccents == 1, cased.contains(false) {
        score += 1
      }
      let alphabetic = families.isSubset(of: [.latin, .cyrillic, .greek])
      if foreignLetters > 0, alphabetic, letters >= 3, vowelCount * 5 < letters {
        score -= Double(letters)
      }
      // Thai writes most vowels as signs; a long run of consonants alone is misread bytes.
      if thaiLetters >= 4, thaiVowels * 5 < thaiLetters { score -= Double(thaiLetters) }
      // A lone letter, like a currency sign read as a Cyrillic one, proves nothing.
      if letters == 1, cjkLetters == 0 { score = min(score, before) }
    }
    return score
  }

  /// Lowercase, uppercase, or a capital followed by lowercase letters.
  private static func isOrdinaryCase(_ uppercase: [Bool]) -> Bool {
    let rest = uppercase.dropFirst()
    return uppercase.allSatisfy { $0 } || rest.allSatisfy { !$0 }
  }

  /// Han characters a code page's own decoding should mostly produce: the frequently used
  /// first level of GB 2312, Big5 and JIS X 0208. Misread text lands on rare characters.
  private static let gb18030 = encoding(.GB_18030_2000)
  private static let gb2312 = encoding(.EUC_CN)
  private static let big5 = encoding(.dosChineseTrad)
  private static let korean = encoding(.dosKorean)
  private static let ksX1001 = encoding(.EUC_KR)
  private static let shiftJIS = encoding(.dosJapanese)

  /// Han characters a code page's own decoding should mostly produce: the frequently used
  /// first level of GB 2312, Big5 and JIS X 0208. Misread text lands on rare characters.
  private static func isCommon(_ scalar: Unicode.Scalar, for candidate: Candidate) -> Bool {
    let lead: (String.Encoding, ClosedRange<UInt8>)
    switch candidate.encoding {
    case gb18030: lead = (gb2312, 0xB0...0xD7)
    case big5: lead = (big5, 0xA4...0xC6)
    // Legacy Korean taggers could write only the KS X 1001 syllables; Hanja in a title is
    // rare, so it counts as uncommon.
    case korean:
      guard script(of: scalar) == .hangul else { return false }
      lead = (ksX1001, 0xB0...0xC8)
    case shiftJIS: lead = (shiftJIS, 0x88...0x98)
    default: return true
    }
    guard let bytes = String(scalar).data(using: lead.0), bytes.count == 2 else { return false }
    return lead.1.contains(bytes[0])
  }

  private static func script(of scalar: Unicode.Scalar) -> Script {
    switch scalar.value {
    case 0x00C0...0x024F, 0x1E00...0x1EFF: return .latin
    case 0x0400...0x052F: return .cyrillic
    case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
    case 0x0590...0x05FF: return .hebrew
    case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
    case 0x0E00...0x0E7F: return .thai
    case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF61...0xFF9F: return .kana
    case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .han
    default: return .other
    }
  }
}
