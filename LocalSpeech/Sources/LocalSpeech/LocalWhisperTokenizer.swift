import Foundation
import NaturalLanguage
@preconcurrency import WhisperKit

/// Moved from the lab backend. WhisperKit 1.1.0 keeps its wrapper initializer
/// internal; this adapter permits the strictly local public tokenizer factory.
struct LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper) throws {
        func token(_ text: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(text) else {
                throw LocalSpeechError("Local Whisper tokenizer is missing required token \(text).")
            }
            return id
        }
        self.tokenizer = tokenizer
        specialTokens = try SpecialTokens(
            endToken: token("<|endoftext|>"),
            englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"),
            noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"),
            startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"),
            timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"),
            translateToken: token("<|translate|>"),
            whitespaceToken: token("Ġ")
        )
        allLanguageTokens = Set(Constants.languages.values.compactMap {
            tokenizer.convertTokenToId("<|\($0)|>")
        })
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    // Group complete Unicode tokens, then space-delimited subwords, following
    // the SDK's language convention. Timing itself comes from its alignment heads
    // and dynamic-time-warping implementation, never from this token grouping.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let language = recognizer.dominantLanguage.flatMap {
            Locale(identifier: $0.rawValue).language.languageCode?.identifier
        }
        let splitOnUnicode = ["zh", "ja", "th", "lo", "my", "yue"].contains(language)
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var pending: [Int] = []
        for (index, id) in tokenIds.enumerated() {
            pending.append(id)
            let text = decode(tokens: pending)
            if text.contains("\u{fffd}"), index < tokenIds.count - 1 { continue }
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if splitOnUnicode || words.isEmpty || pending[0] >= specialTokens.specialTokenBegin || text.hasPrefix(" ") || punctuation {
                words.append(text)
                wordTokens.append(pending)
            } else {
                words[words.count - 1] += text
                wordTokens[wordTokens.count - 1].append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
        }
        return (words, wordTokens)
    }
}
