import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Downloads the dictionary's packs, hosted by the App Store, while the app isn't running:
/// the core at install, and any language the app has asked for (LanguagePacks).
@main
struct Downloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool { true }
}
