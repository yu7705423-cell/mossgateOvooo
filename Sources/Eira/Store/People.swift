import Foundation

/// 角色、身份、会话之间的几件事：新建、找会话、删除、切身份。规矩照网页版。
enum People {
    // MARK: - 角色

    /// 新建一个角色。字段与默认值照网页版「联系」的新建（apps/contact/App.js）。
    static func createCharacter(name: String = "新角色") throws -> Character {
        let row = Row.new(prefix: "char", [
            "name": .string(name), "persona": .string(""), "signature": .string(""), "group": .string(""),
            "lorebookIds": .array([]), "canSendVoice": .bool(true), "canSendImage": .bool(true), "parentId": .null,
        ])
        try Database.shared.put(Collections.characters, row)
        return Character(row: row)
    }

    /// 改角色的几个字段。只动 fields 里给的那几项，其余字段（网页版的各种开关、状态）原样留着。
    static func update(_ char: Character, _ fields: [String: JSONValue]) throws -> Character {
        var row = char.row
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(Collections.characters, row)
        return Character(row: row)
    }

    /// 删除一个角色，连同挂在它身上的东西（网页版 purge.js 的 dropCharacter）：
    /// 它的单聊整段删掉；群聊只把它移出去，移完不够两人的群整个删掉；它的记忆，以及按角色挂着的那些数据域。
    static func deleteCharacter(_ id: String) throws {
        for chat in try Repo.chats() where chat.characterIds.contains(id) {
            let rest = chat.characterIds.filter { $0 != id }
            if chat.row.bool("group") && rest.count >= 2 {
                var c = chat
                c.row["characterIds"] = .array(rest.map { .string($0) })
                c.row.touch()
                try Repo.save(c)
            } else {
                try deleteChat(chat.id)
            }
        }
        for collection in byCharacter { try Database.shared.deleteAll(collection, where: id) }
        try Database.shared.delete(Collections.characters, id: id)
    }

    /// 按 charId 查的数据域（Collections.indexField 里查询字段是 charId 的那几个，含记忆）。
    static var byCharacter: [String] {
        Collections.indexField.filter { $0.value == "charId" }.map(\.key).sorted()
    }

    /// 删一段会话与它的全部消息，以及按 chatId 挂着的数据域。
    static func deleteChat(_ id: String) throws {
        for collection in Collections.indexField.filter({ $0.value == "chatId" }).map(\.key) {
            try Database.shared.deleteAll(collection, where: id)
        }
        try Database.shared.delete(Collections.chats, id: id)
    }

    // MARK: - 会话

    /// 会话属于「某个身份 + 某个角色」：找得到就用那一段，找不到新建（网页版 apps/chat/helpers.js 的 chatFor）。
    /// 换成小号去找同一个角色，开的是新会话。
    static func chatFor(charId: String, personaId: String) throws -> Chat {
        if let found = try Repo.chats().first(where: {
            $0.characterIds == [charId] && !$0.row.bool("group") && $0.personaId == personaId
        }) { return found }
        let row = Row.new(prefix: "chat", [
            "characterIds": .array([.string(charId)]), "personaId": .string(personaId),
            "title": .string(""), "lastMessageAt": .number(Date().millis), "unread": .number(0), "summary": .string(""),
        ])
        try Database.shared.put(Collections.chats, row)
        return Chat(row: row)
    }

    // MARK: - 身份

    /// 新建一个身份。parentId 为空是大号，否则是那个大号的小号（网页版 accounts.js）。
    static func createPersona(name: String, parentId: String? = nil) throws -> Persona {
        let row = Row.new(prefix: "me", [
            "name": .string(name), "avatar": .null, "cover": .null, "signature": .string(""), "description": .string(""),
            "parentId": parentId.map { .string($0) } ?? .null,
        ])
        try Database.shared.put(Collections.personas, row)
        return Persona(row: row)
    }

    static func update(_ p: Persona, _ fields: [String: JSONValue]) throws -> Persona {
        var row = p.row
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(Collections.personas, row)
        return Persona(row: row)
    }

    static func setActivePersona(_ id: String) throws {
        var s = try AppSettings.loadForWrite()
        s.raw["activePersonaId"] = .string(id)
        try s.save()
    }

    /// 当前身份；一个都没有（从空白开始用）时建一个大号「我」并设为当前。
    static func ensureActivePersona() throws -> Persona {
        if let p = try Repo.activePersona() { return p }
        let p = try createPersona(name: "我")
        try setActivePersona(p.id)
        return p
    }
}
