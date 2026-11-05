// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import BazerCore

struct BluetoothAudioMatch: Sendable {
    var key: String
    var name: String
    var discoveryKeys: Set<String>
    var powerKeys: Set<String>
    var power: [BluetoothAudioPowerRecord]
    var quality: BluetoothAudioIdentityQuality
    var preferenceIdentity: String?
    var message: String?
    var hasConflict = false
    var nameDiscoveryKeys: Set<String> = []
}

enum BluetoothAudioMatcher {
    static func match(discovery: [BluetoothAudioDiscoveryRecord], power: [BluetoothAudioPowerRecord],
                      suppressedDiscoveryKeys: Set<String> = []) -> [BluetoothAudioMatch] {
        let connected = discovery.filter(\.isConnected)
        let groups = Dictionary(grouping: power.filter(\.isPresent)) { $0.groupKey.map { "group:" + $0 } ?? "power:" + $0.key }
        let names = Dictionary(grouping: connected, by: \.name)
        let powerNames = Dictionary(grouping: groups.values, by: { $0.first!.name })
        let identities = Dictionary(grouping: groups.values.compactMap { records -> String? in
            let values = Set(records.compactMap(\.verifiedPreferenceIdentity)); return values.count == 1 ? values.first : nil
        }, by: { $0 })
        var consumed = Set<String>()
        var results: [BluetoothAudioMatch] = []
        for key in groups.keys.sorted() {
            let parts = groups[key]!
            let name = parts[0].name
            let explicit = Set(parts.compactMap(\.directDiscoveryKey))
            let direct = explicit.count == 1 ? connected.filter { explicit.contains($0.key) } : []
            let sameName = names[name] ?? []
            let unique = sameName.count == 1 && powerNames[name]?.count == 1
            let joined = direct.count == 1 ? direct : explicit.isEmpty && unique ? sameName : []
            consumed.formUnion(joined.map(\.key))
            let ambiguous = sameName.count > 1 || (powerNames[name]?.count ?? 0) > 1 || explicit.count > 1
            let components = parts.map(\.component).filter { $0 != .unknown }
            let conflict = explicit.count > 1 || Set(parts.map(\.key)).count != parts.count
                || Set(components).count != components.count || (components.count > 1 && components.contains(.single))
            let preferences = Set(parts.compactMap(\.verifiedPreferenceIdentity))
            // Name-only correlation never inherits a discovery identity, even if its address is verified.
            let ownPreference = preferences.count == 1 ? preferences.first : nil
            let identityCollision = ownPreference.map { identities[$0]?.count != 1 } ?? false
            let preference = !conflict && !identityCollision ? ownPreference : nil
            results.append(.init(key: key, name: name, discoveryKeys: Set(joined.map(\.key)), powerKeys: Set(parts.map(\.key)),
                power: parts, quality: conflict || identityCollision ? .ambiguous : preference != nil ? .verified : ambiguous ? .ambiguous : .sessionOnly,
                preferenceIdentity: preference,
                message: conflict ? "系统部件记录冲突，电量待确认" : ambiguous ? "同名设备关联不明确，仅显示系统配件记录" : preference == nil ? "身份仅在本次连接有效，低电量提醒不可用" : nil,
                hasConflict: conflict, nameDiscoveryKeys: explicit.isEmpty ? Set(joined.map(\.key)) : []))
        }
        // An unresolved same-name report is an accessory card, never a second discovery card.
        // The records are not merged by name; their battery and identity remain wholly separate.
        let reportedNames = Set(power.filter(\.isPresent).map(\.name))
        for item in connected where !consumed.contains(item.key) && !reportedNames.contains(item.name) && !suppressedDiscoveryKeys.contains(item.key) {
            results.append(.init(key: "discovery:" + item.key, name: item.name, discoveryKeys: [item.key], powerKeys: [], power: [],
                quality: item.verifiedPreferenceIdentity == nil ? .sessionOnly : .verified,
                preferenceIdentity: item.verifiedPreferenceIdentity, message: "系统未提供耳机电量"))
        }
        return results
    }
}
