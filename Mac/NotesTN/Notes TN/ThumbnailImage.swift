import SwiftUI
import UIKit
import ImageIO

// Note-list row thumbnail — replaces AsyncImage(url:) for local resource files.
//
// AsyncImage decoded the ORIGINAL image at full size for a 44pt square (a 12MP
// photo decodes to a ~45MB bitmap), re-read and re-decoded from disk every time a
// row scrolled back into view (URLSession doesn't cache file:// URLs). This uses
// ImageIO's CGImageSourceCreateThumbnailAtIndex to decode straight to thumbnail
// size on a background queue, cached in an NSCache keyed by filename — resource
// files are content-addressed ("<resourceId>.<ext>") and never rewritten, so a
// cached thumbnail can't go stale.
//
// Used by PadNoteListView (iPad) and NoteListView (iPhone) in this folder.
struct ThumbnailImage: View {
    let url: URL
    var maxPixelSize: CGFloat = 132   // 44pt @3x

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _, _ in
            image = nil
            load()
        }
    }

    private func load() {
        let key = url.lastPathComponent as NSString
        if let cached = ThumbnailCache.storage.object(forKey: key) {
            image = cached
            return
        }
        let url = self.url
        let maxPixelSize = self.maxPixelSize
        DispatchQueue.global(qos: .userInitiated).async {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            var thumbnail: UIImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) {
                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    // Applies EXIF orientation while downsampling, so photos don't
                    // come out sideways.
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as [CFString: Any] as CFDictionary
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
                    thumbnail = UIImage(cgImage: cg)
                }
            }
            DispatchQueue.main.async {
                if let thumbnail {
                    ThumbnailCache.storage.setObject(thumbnail, forKey: key)
                }
                // Only apply if this view still shows the same file (rows are reused
                // while scrolling).
                if self.url.lastPathComponent == key as String {
                    self.image = thumbnail
                }
            }
        }
    }
}

enum ThumbnailCache {
    static let storage: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}
