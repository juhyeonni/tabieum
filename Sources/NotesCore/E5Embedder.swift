import CoreML
import Foundation
import Hub
import Tokenizers

/// multilingual-e5-small converted to Core ML and run on the Neural Engine. The model loads on first use and unloads
/// after `idleSeconds` without one. Queries and stored passages get the prefixes the model was trained with.
public final class E5Embedder: Embedder, @unchecked Sendable {
    static let sequenceLength = 256
    static let padToken: Int32 = 1
    static let endToken = 2

    private struct Runtime {
        let model: MLModel
        let tokenizer: Tokenizer
    }

    private let source: ModelSource
    private let store: ModelStore
    private let idleSeconds: TimeInterval
    private let lock = NSLock()
    private var runtime: Runtime?
    private var unload: DispatchWorkItem?

    public init(source: ModelSource = .e5Small, store: ModelStore, idleSeconds: TimeInterval = 60) {
        self.source = source
        self.store = store
        self.idleSeconds = idleSeconds
    }

    public static func standardStore(bundleIdentifier: String? = ProductInfo.main?.bundleIdentifier) -> ModelStore {
        ModelStore(source: .e5Small, bundleIdentifier: bundleIdentifier ?? "dev.juhyeonni.tabieum")
    }

    public static func standard() -> E5Embedder {
        E5Embedder(store: standardStore())
    }

    public var fingerprint: String { source.versionedID }

    public func modelID(for text: String) -> String? { source.versionedID }

    public func isReady(_ modelID: String) -> Bool {
        modelID == source.versionedID && store.isInstalled(source)
    }

    public var isLoaded: Bool {
        lock.withLock { runtime != nil }
    }

    public func embed(_ text: String, modelID: String) throws -> [Float] {
        try embed(text, modelID: modelID, kind: .passage)
    }

    public func embed(_ text: String, modelID: String, kind: EmbeddingKind) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard modelID == source.versionedID else { throw SQLiteError(message: "unknown model \(modelID)", code: 0) }
        let runtime = try loadedRuntime()
        scheduleUnload()
        let prefix = kind == .query ? "query: " : "passage: "
        let (ids, mask) = Self.padded(runtime.tokenizer.encode(text: prefix + text))
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": Self.array(ids), "attention_mask": Self.array(mask)])
        guard let output = try runtime.model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue else {
            throw SQLiteError(message: "the model returned no embedding", code: 0)
        }
        return Vector.normalized((0..<output.count).map { output[$0].floatValue })
    }

    func tokenIDs(for text: String) throws -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return try loadedRuntime().tokenizer.encode(text: text)
    }

    /// Token ids cut to the model's length, keeping the closing token, and padded; with the attention mask.
    static func padded(_ ids: [Int]) -> (ids: [Int32], mask: [Int32]) {
        let kept = ids.count > sequenceLength ? Array(ids.prefix(sequenceLength - 1)) + [endToken] : ids
        let padding = sequenceLength - kept.count
        return (kept.map(Int32.init) + [Int32](repeating: padToken, count: padding),
                [Int32](repeating: 1, count: kept.count) + [Int32](repeating: 0, count: padding))
    }

    private static func array(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return array
    }

    private func loadedRuntime() throws -> Runtime {
        if let runtime { return runtime }
        guard store.isInstalled(source) else { throw SQLiteError(message: "the embedding model is not installed", code: 0) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = Runtime(model: try MLModel(contentsOf: store.compiledModel, configuration: configuration),
                             tokenizer: try tokenizer())
        runtime = loaded
        return loaded
    }

    private func tokenizer() throws -> Tokenizer {
        func config(_ name: String) throws -> Config {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file(name)))
            guard let dictionary = object as? [NSString: Any] else { throw SQLiteError(message: "\(name) is not an object", code: 0) }
            return Config(dictionary)
        }
        return try AutoTokenizer.from(tokenizerConfig: config("tokenizer_config.json"), tokenizerData: config("tokenizer.json"))
    }

    private func scheduleUnload() {
        unload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.withLock { runtime = nil }
        }
        unload = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleSeconds, execute: work)
    }
}

public enum EmbeddingModel: String, CaseIterable, Sendable {
    case apple, e5Small

    public static let defaultsKey = "embeddingModel"

    /// tabieum-e5-small-coreml is converted for the Neural Engine of an Apple silicon Mac, so an Intel Mac uses the built-in model.
    public static var e5Available: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public init(defaults: UserDefaults = .standard, e5Available: Bool = Self.e5Available) {
        let stored = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .apple
        self = stored == .e5Small && !e5Available ? .apple : stored
    }
}

/// The embedder the user picked in Settings. It follows the setting on every call, so a running index service switches
/// without being restarted; vectors of different models stay apart because the model id is part of each stored chunk.
public final class ConfiguredEmbedder: Embedder, @unchecked Sendable {
    private let defaults: UserDefaults
    private let apple: Embedder
    private let e5: Embedder
    private let e5Available: Bool

    public init(
        defaults: UserDefaults = .standard, apple: Embedder = AppleEmbedder(), e5: Embedder = E5Embedder.standard(),
        e5Available: Bool = EmbeddingModel.e5Available
    ) {
        self.defaults = defaults
        self.apple = apple
        self.e5 = e5
        self.e5Available = e5Available
    }

    private var current: Embedder { EmbeddingModel(defaults: defaults, e5Available: e5Available) == .e5Small ? e5 : apple }

    public var fingerprint: String { current.fingerprint }
    public func modelID(for text: String) -> String? { current.modelID(for: text) }
    public func isReady(_ modelID: String) -> Bool { current.isReady(modelID) }
    public func embed(_ text: String, modelID: String) throws -> [Float] { try current.embed(text, modelID: modelID) }
    public func embed(_ text: String, modelID: String, kind: EmbeddingKind) throws -> [Float] {
        try current.embed(text, modelID: modelID, kind: kind)
    }
}
