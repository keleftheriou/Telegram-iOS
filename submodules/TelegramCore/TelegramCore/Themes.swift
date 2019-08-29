import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import TelegramApiMac
#else
    import Postbox
    import SwiftSignalKit
    import TelegramApi
#endif

final class CachedThemesConfiguration: PostboxCoding {
    let hash: Int32
    
    init(hash: Int32) {
        self.hash = hash
    }
    
    init(decoder: PostboxDecoder) {
        self.hash = decoder.decodeInt32ForKey("hash", orElse: 0)
    }
    
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.hash, forKey: "hash")
    }
}

#if os(macOS)
private let themeFormat = "macos"
private let themeFileExtension = "palette"
#else
private let themeFormat = "ios"
private let themeFileExtension = "tgios-theme"
#endif

public func telegramThemes(postbox: Postbox, network: Network, forceUpdate: Bool = false) -> Signal<[TelegramTheme], NoError> {
    let fetch: ([TelegramTheme]?, Int32?) -> Signal<[TelegramTheme], NoError> = { current, hash in
        network.request(Api.functions.account.getThemes(format: themeFormat, hash: hash ?? 0))
        |> retryRequest
        |> mapToSignal { result -> Signal<([TelegramTheme], Int32), NoError> in
            switch result {
                case let .themes(hash, themes):
                    let result = themes.compactMap { TelegramTheme(apiTheme: $0) }
                    if result == current {
                        return .complete()
                    } else {
                        return .single((result, hash))
                    }
                case .themesNotModified:
                    return .complete()
            }
        }
        |> mapToSignal { items, hash -> Signal<[TelegramTheme], NoError> in
            return postbox.transaction { transaction -> [TelegramTheme] in
                var entries: [OrderedItemListEntry] = []
                for item in items {
                    var intValue = Int32(entries.count)
                    let id = MemoryBuffer(data: Data(bytes: &intValue, count: 4))
                    entries.append(OrderedItemListEntry(id: id, contents: item))
                }
                transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudThemes, items: entries)
                transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedThemesConfiguration, key: ValueBoxKey(length: 0)), entry: CachedThemesConfiguration(hash: hash), collectionSpec: ItemCacheCollectionSpec(lowWaterItemCount: 1, highWaterItemCount: 1))
                return items
            }
        } |> then(
            postbox.combinedView(keys: [PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.CloudThemes)])
            |> map { view -> [TelegramTheme] in
                if let view = view.views[.orderedItemList(id: Namespaces.OrderedItemList.CloudThemes)] as? OrderedItemListView {
                    return view.items.compactMap { $0.contents as? TelegramTheme }
                } else {
                    return []
                }
            }
        )
    }
    
    if forceUpdate {
        return fetch(nil, nil)
    } else {
        return postbox.transaction { transaction -> ([TelegramTheme], Int32?) in
            let configuration = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedThemesConfiguration, key: ValueBoxKey(length: 0))) as? CachedThemesConfiguration
            let items = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudThemes)
            return (items.map { $0.contents as! TelegramTheme }, configuration?.hash)
        }
        |> mapToSignal { current, hash -> Signal<[TelegramTheme], NoError> in
            return .single(current)
            |> then(fetch(current, hash))
        }
    }
}

public enum GetThemeError {
    case generic
    case unsupported
}

public func getTheme(account: Account, slug: String) -> Signal<TelegramTheme, GetThemeError> {
    return account.network.request(Api.functions.account.getTheme(format: themeFormat, theme: .inputThemeSlug(slug: slug), documentId: 0))
    |> mapError { error -> GetThemeError in
        if error.errorDescription == "THEME_FORMAT_INVALID" {
            return .unsupported
        }
        return .generic
    }
    |> mapToSignal { theme -> Signal<TelegramTheme, GetThemeError> in
        if let theme = TelegramTheme(apiTheme: theme) {
            return .single(theme)
        } else {
            return .fail(.generic)
        }
    }
}

public enum CheckThemeUpdatedResult {
    case updated(TelegramTheme)
    case notModified
}

public func checkThemeUpdated(account: Account, theme: TelegramTheme) -> Signal<CheckThemeUpdatedResult, GetThemeError> {
    guard let file = theme.file, let fileId = file.id?.id else {
        return .fail(.generic)
    }
    return account.network.request(Api.functions.account.getTheme(format: themeFormat, theme: .inputTheme(id: theme.id, accessHash: theme.accessHash), documentId: fileId))
    |> mapError { _ -> GetThemeError in return .generic }
    |> map { theme -> CheckThemeUpdatedResult in
        if let theme = TelegramTheme(apiTheme: theme) {
            return .updated(theme)
        } else {
            return .notModified
        }
    }
}

private func saveUnsaveTheme(account: Account, theme: TelegramTheme, unsave: Bool) -> Signal<Void, NoError> {
    return account.postbox.transaction { transaction -> Signal<Void, NoError> in
        let entries = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudThemes)
        var items = entries.map { $0.contents as! TelegramTheme }
        items = items.filter { $0.id != theme.id }
        if !unsave {
            items.insert(theme, at: 0)
        }
        var updatedEntries: [OrderedItemListEntry] = []
        for item in items {
            var intValue = Int32(updatedEntries.count)
            let id = MemoryBuffer(data: Data(bytes: &intValue, count: 4))
            updatedEntries.append(OrderedItemListEntry(id: id, contents: item))
        }
        transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudThemes, items: updatedEntries)
        
        return account.network.request(Api.functions.account.saveTheme(theme: Api.InputTheme.inputTheme(id: theme.id, accessHash: theme.accessHash), unsave: unsave ? Api.Bool.boolTrue : Api.Bool.boolFalse))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .complete()
        }
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return telegramThemes(postbox: account.postbox, network: account.network, forceUpdate: true)
            |> take(1)
            |> mapToSignal { _ -> Signal<Void, NoError> in
                return .complete()
            }
        }
    } |> switchToLatest
}

private func installTheme(account: Account, theme: TelegramTheme) -> Signal<Never, NoError> {
    return account.network.request(Api.functions.account.installTheme(format: themeFormat, theme: Api.InputTheme.inputTheme(id: theme.id, accessHash: theme.accessHash)))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .complete()
    }
    |> mapToSignal { _ -> Signal<Never, NoError> in
        return .complete()
    }
}

public enum UploadThemeResult {
    case progress(Float)
    case complete(TelegramMediaFile)
}

public enum UploadThemeError {
    case generic
}

private struct UploadedThemeData {
    fileprivate let content: UploadedThemeDataContent
}

private enum UploadedThemeDataContent {
    case result(MultipartUploadResult)
    case error
}

private func uploadedTheme(postbox: Postbox, network: Network, resource: MediaResource) -> Signal<UploadedThemeData, NoError> {
    return multipartUpload(network: network, postbox: postbox, source: .resource(.standalone(resource: resource)), encrypt: false, tag: TelegramMediaResourceFetchTag(statsCategory: .file), hintFileSize: nil, hintFileIsLarge: false)
    |> map { result -> UploadedThemeData in
        return UploadedThemeData(content: .result(result))
    }
    |> `catch` { _ -> Signal<UploadedThemeData, NoError> in
        return .single(UploadedThemeData(content: .error))
    }
}

private func uploadedThemeThumbnail(postbox: Postbox, network: Network, data: Data) -> Signal<UploadedThemeData, NoError> {
    return multipartUpload(network: network, postbox: postbox, source: .data(data), encrypt: false, tag: TelegramMediaResourceFetchTag(statsCategory: .image), hintFileSize: nil, hintFileIsLarge: false)
    |> map { result -> UploadedThemeData in
        return UploadedThemeData(content: .result(result))
    }
    |> `catch` { _ -> Signal<UploadedThemeData, NoError> in
        return .single(UploadedThemeData(content: .error))
    }
}

private func uploadTheme(account: Account, resource: MediaResource, thumbnailData: Data? = nil) -> Signal<UploadThemeResult, UploadThemeError> {
    let fileName = "theme.\(themeFileExtension)"
    let mimeType = "application/x-tgtheme-\(themeFormat)"
    
    let uploadedThumbnail: Signal<UploadedThemeData?, UploadThemeError>
    if let thumbnailData = thumbnailData {
        uploadedThumbnail = uploadedThemeThumbnail(postbox: account.postbox, network: account.network, data: thumbnailData)
        |> mapError { _ -> UploadThemeError in return .generic }
        |> map(Optional.init)
    } else {
        uploadedThumbnail = .single(nil)
    }
    
    return uploadedThumbnail
    |> mapToSignal { thumbnailResult -> Signal<UploadThemeResult, UploadThemeError> in
        return uploadedTheme(postbox: account.postbox, network: account.network, resource: resource)
        |> mapError { _ -> UploadThemeError in return .generic }
        |> mapToSignal { result -> Signal<UploadThemeResult, UploadThemeError> in
            switch result.content {
                case .error:
                    return .fail(.generic)
                case let .result(resultData):
                    switch resultData {
                        case let .progress(progress):
                            return .single(.progress(progress))
                        case let .inputFile(file):
                            var flags: Int32 = 0
                            var thumbnailFile: Api.InputFile?
                            if let thumbnailResult = thumbnailResult?.content, case let .result(result) = thumbnailResult, case let .inputFile(file) = result {
                                thumbnailFile = file
                                flags |= 1 << 0
                            }
                            return account.network.request(Api.functions.account.uploadTheme(flags: flags, file: file, thumb: thumbnailFile, fileName: fileName, mimeType: mimeType))
                            |> mapError { _ in return UploadThemeError.generic }
                            |> mapToSignal { document -> Signal<UploadThemeResult, UploadThemeError> in
                                if let file = telegramMediaFileFromApiDocument(document) {
                                    return .single(.complete(file))
                                } else {
                                    return .fail(.generic)
                                }
                            }
                        default:
                            return .fail(.generic)
                    }
            }
        }
    }
}

public enum CreateThemeError {
    case generic
    case slugOccupied
}

public enum CreateThemeResult {
    case result(TelegramTheme)
    case progress(Float)
}

public func createTheme(account: Account, title: String, resource: MediaResource, thumbnailData: Data? = nil) -> Signal<CreateThemeResult, CreateThemeError> {
    return uploadTheme(account: account, resource: resource, thumbnailData: thumbnailData)
    |> mapError { _ in return CreateThemeError.generic }
    |> mapToSignal { result -> Signal<CreateThemeResult, CreateThemeError> in
        switch result {
            case let .complete(file):
                if let resource = file.resource as? CloudDocumentMediaResource {
                    return account.network.request(Api.functions.account.createTheme(slug: "", title: title, document: .inputDocument(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference))))
                    |> mapError { _ in return CreateThemeError.generic }
                    |> mapToSignal { apiTheme -> Signal<CreateThemeResult, CreateThemeError> in
                        if let theme = TelegramTheme(apiTheme: apiTheme) {
                            return account.postbox.transaction { transaction -> CreateThemeResult in
                                let entries = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudThemes)
                                var items = entries.map { $0.contents as! TelegramTheme }
                                items.insert(theme, at: 0)
                                var updatedEntries: [OrderedItemListEntry] = []
                                for item in items {
                                    var intValue = Int32(updatedEntries.count)
                                    let id = MemoryBuffer(data: Data(bytes: &intValue, count: 4))
                                    updatedEntries.append(OrderedItemListEntry(id: id, contents: item))
                                }
                                transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudThemes, items: updatedEntries)
                                return .result(theme)
                            }
                            |> introduceError(CreateThemeError.self)
                        } else {
                            return .fail(.generic)
                        }
                    }
                }
                else {
                    return .fail(.generic)
                }
            case let .progress(progress):
                return .single(.progress(progress))
        }
    }
}

public func updateTheme(account: Account, theme: TelegramTheme, title: String?, slug: String?, resource: MediaResource?, thumbnailData: Data? = nil) -> Signal<CreateThemeResult, CreateThemeError> {
    guard title != nil || slug != nil || resource != nil else {
        return .complete()
    }
    var flags: Int32 = 0
    if let _ = title {
        flags |= 1 << 1
    }
    if let _ = slug {
        flags |= 1 << 0
    }
    let uploadSignal: Signal<UploadThemeResult?, UploadThemeError>
    if let resource = resource {
        flags |= 1 << 2
        uploadSignal = uploadTheme(account: account, resource: resource, thumbnailData: thumbnailData)
        |> map(Optional.init)
    } else {
        uploadSignal = .single(nil)
    }
    return uploadSignal
    |> mapError { _ -> CreateThemeError in
        return .generic
    }
    |> mapToSignal { result -> Signal<CreateThemeResult, CreateThemeError> in
        let inputDocument: Api.InputDocument?
        if let status = result {
            switch status {
                case let .complete(file):
                    if let resource = file.resource as? CloudDocumentMediaResource {
                        inputDocument = .inputDocument(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference))
                    } else {
                        return .fail(.generic)
                    }
                case let .progress(progress):
                    return .single(.progress(progress))
            }
        } else {
            inputDocument = nil
        }
        
        return account.network.request(Api.functions.account.updateTheme(flags: flags, theme: .inputTheme(id: theme.id, accessHash: theme.accessHash), slug: slug, title: title, document: inputDocument))
        |> mapError { error -> CreateThemeError in
            if error.errorDescription.hasPrefix("THEME_SLUG_OCCUPIED") {
                return .slugOccupied
            }
            return .generic
        }
        |> mapToSignal { apiTheme -> Signal<CreateThemeResult, CreateThemeError> in
            if let result = TelegramTheme(apiTheme: apiTheme) {
                return account.postbox.transaction { transaction -> CreateThemeResult in
                    let entries = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudThemes)
                    let items = entries.map { entry -> TelegramTheme in
                        let theme = entry.contents as! TelegramTheme
                        if theme.id == result.id {
                            return result
                        } else {
                            return theme
                        }
                    }
                    var updatedEntries: [OrderedItemListEntry] = []
                    for item in items {
                        var intValue = Int32(updatedEntries.count)
                        let id = MemoryBuffer(data: Data(bytes: &intValue, count: 4))
                        updatedEntries.append(OrderedItemListEntry(id: id, contents: item))
                    }
                    transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudThemes, items: updatedEntries)
                    return .result(result)
                }
                |> introduceError(CreateThemeError.self)
            } else {
                return .fail(.generic)
            }
        }
    }
}

public final class ThemeSettings: PreferencesEntry, Equatable {
    public let currentTheme: TelegramTheme?
 
    public init(currentTheme: TelegramTheme?) {
        self.currentTheme = currentTheme
    }
    
    public init(decoder: PostboxDecoder) {
        self.currentTheme = decoder.decodeObjectForKey("t", decoder: { TelegramTheme(decoder: $0) }) as? TelegramTheme
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        if let currentTheme = currentTheme {
            encoder.encodeObject(currentTheme, forKey: "t")
        } else {
            encoder.encodeNil(forKey: "t")
        }
    }
    
    public func isEqual(to: PreferencesEntry) -> Bool {
        if let to = to as? ThemeSettings {
            return self == to
        } else {
            return false
        }
    }
    
    public static func ==(lhs: ThemeSettings, rhs: ThemeSettings) -> Bool {
        return lhs.currentTheme == rhs.currentTheme
    }
}

public func saveThemeInteractively(account: Account, theme: TelegramTheme) -> Signal<Void, NoError> {
    return saveUnsaveTheme(account: account, theme: theme, unsave: false)
}

public func deleteThemeInteractively(account: Account, theme: TelegramTheme) -> Signal<Void, NoError> {
    return saveUnsaveTheme(account: account, theme: theme, unsave: true)
}

public func applyTheme(accountManager: AccountManager, account: Account, theme: TelegramTheme?) -> Signal<Never, NoError> {
    return accountManager.transaction { transaction -> Signal<Never, NoError> in
        transaction.updateSharedData(SharedDataKeys.themeSettings, { _ in
            return ThemeSettings(currentTheme: theme)
        })
        
        if let theme = theme {
            return installTheme(account: account, theme: theme)
        } else {
            return .complete()
        }
    }
    |> switchToLatest
}