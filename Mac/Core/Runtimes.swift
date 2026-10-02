// The providers, models and efforts a session can be started on, from what `runtimes` answers.
import Foundation

struct RuntimeModel: Equatable, Sendable {
    var id: String
    var label: String?
    /// Nil when the server sent no list, which a save keeps apart from an empty one.
    var efforts: [String]?
    var defaultEffort: String?

    /// A model without a label goes by its id.
    var title: String { (label ?? "").isEmpty ? id : label! }
}

struct RuntimeProvider: Equatable, Sendable {
    var id: Int
    var label: String
    /// Nil when the server left it out (the C client's -1).
    var available: Bool?
    var models: [RuntimeModel]
    var defaultModel: String?

    /// Only an explicit false greys a provider out; older servers omit the field.
    var isAvailable: Bool { available != false }
}

/// What a start is asked to run on (`provider`, `model`, `effort`). The server may still fall back to a default model or effort.
struct RuntimeChoice: Equatable, Hashable, Sendable {
    var providerId: Int
    var model: String?
    var effort: String?

    init(providerId: Int, model: String? = nil, effort: String? = nil) { self.providerId = providerId; self.model = model; self.effort = effort }
    /// Needs a numeric `providerId`.
    init?(_ j: JSON) {
        guard let id = j["providerId"].truncatedInt else { return nil }
        providerId = id; model = j["model"].string; effort = j["effort"].string
    }
    var json: JSON { ["providerId": JSON(providerId), "model": .string(orNull: model), "effort": .string(orNull: effort)] }
    /// Starts send "provider", as the client API names it; empty strings are left out.
    var arguments: JSON {
        var o: JSON = ["provider": JSON(providerId)]
        if let model, !model.isEmpty { o["model"] = .string(model) }
        if let effort, !effort.isEmpty { o["effort"] = .string(effort) }
        return o
    }
}

struct RuntimeCatalog: Equatable, Sendable {
    /// The project's default runtime; nil without one (a default without a provider is no default).
    var defaultChoice: RuntimeChoice?
    var providers: [RuntimeProvider]

    init(defaultChoice: RuntimeChoice? = nil, providers: [RuntimeProvider] = []) { self.defaultChoice = defaultChoice; self.providers = providers }
    /// Fails as a whole on a provider without a numeric id, a string label or a models array, or a model without a string id.
    init?(_ j: JSON) {
        guard let list = j["providers"].array else { return nil }
        defaultChoice = RuntimeChoice(j["default"])
        var providers: [RuntimeProvider] = []
        for pv in list {
            guard let id = pv["id"].truncatedInt, let label = pv["label"].string, let models = pv["models"].array else { return nil }
            var out: [RuntimeModel] = []
            for mv in models {
                guard let mid = mv["id"].string else { return nil }
                out.append(RuntimeModel(id: mid, label: mv["label"].string, efforts: mv["efforts"].isArray ? mv["efforts"].strings : nil,
                                        defaultEffort: mv["defaultEffort"].string))
            }
            providers.append(RuntimeProvider(id: id, label: label, available: pv["available"].bool, models: out, defaultModel: pv["defaultModel"].string))
        }
        self.providers = providers
    }
    var json: JSON {
        let providers: [JSON] = self.providers.map { p in
            var pj: JSON = ["id": JSON(p.id), "label": .string(p.label), "defaultModel": .string(orNull: p.defaultModel)]
            if let available = p.available { pj["available"] = .bool(available) }
            pj["models"] = .array(p.models.map { m in
                ["id": .string(m.id), "label": .string(orNull: m.label), "efforts": m.efforts.map { JSON($0) } ?? .null,
                 "defaultEffort": .string(orNull: m.defaultEffort)]
            })
            return pj
        }
        return ["default": defaultChoice?.json ?? .null, "providers": .array(providers)]
    }

    func provider(_ id: Int) -> RuntimeProvider? { providers.first { $0.id == id } }
    func model(for choice: RuntimeChoice) -> RuntimeModel? {
        guard let p = provider(choice.providerId), let model = choice.model else { return nil }
        return p.models.first { $0.id == model }
    }
    /// The efforts the chosen model offers; empty without any.
    func efforts(for choice: RuntimeChoice) -> [String] { model(for: choice)?.efforts ?? [] }
    /// A provider's model with that model's own default effort, since efforts differ between models: the named model, else the
    /// provider's default, else its first. Nil for an unknown provider; a provider without models gives a choice with neither.
    func choice(provider providerId: Int, model: String? = nil) -> RuntimeChoice? {
        guard let p = provider(providerId) else { return nil }
        let picked = p.models.first { model != nil && $0.id == model }
            ?? p.models.first { p.defaultModel != nil && $0.id == p.defaultModel }
            ?? p.models.first
        var out = RuntimeChoice(providerId: providerId)
        if let picked {
            out.model = picked.id
            out.effort = picked.defaultEffort ?? picked.efforts?.first
        }
        return out
    }
    /// Used when the project has no default runtime and a start therefore needs a provider.
    func firstAvailable() -> RuntimeChoice? {
        guard let p = providers.first(where: \.isAvailable) else { return nil }
        return choice(provider: p.id)
    }
    /// "Provider · Model".
    func label(for choice: RuntimeChoice) -> String {
        let p = provider(choice.providerId)
        let model = self.model(for: choice)?.title ?? choice.model
        var s = ""
        if let label = p?.label, !label.isEmpty { s = label }
        if let model, !model.isEmpty { s += (s.isEmpty ? "" : " \u{00B7} ") + model }
        return s
    }
}
