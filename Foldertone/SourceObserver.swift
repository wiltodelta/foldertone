import Foundation

final class SourceObserver: NSObject, NSFilePresenter, @unchecked Sendable {
  enum Change: Sendable {
    case content(URL)
    case moved(URL)
  }
  private let lock = NSLock()
  private var itemURL: URL
  private let accessURL: URL
  private var hasAccess = false
  private var registered = false
  private let changed: @Sendable (Change) -> Void
  let presentedItemOperationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    return queue
  }()

  var presentedItemURL: URL? { lock.withLock { itemURL } }

  init(url: URL, changed: @escaping @Sendable (Change) -> Void) {
    itemURL = url
    accessURL = url
    self.changed = changed
    super.init()
  }

  func start() {
    guard !registered else { return }
    hasAccess = accessURL.startAccessingSecurityScopedResource()
    NSFileCoordinator.addFilePresenter(self)
    registered = true
  }

  func stop() {
    guard registered else { return }
    NSFileCoordinator.removeFilePresenter(self)
    registered = false
    if hasAccess { accessURL.stopAccessingSecurityScopedResource() }
    hasAccess = false
  }

  var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> {
    [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey]
  }
  func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) {
    notifyChange()
  }

  private func notifyChange(_ url: URL? = nil) {
    changed(.content(url ?? presentedItemURL ?? accessURL))
  }
  func presentedItemDidChange() { notifyChange() }
  func presentedSubitemDidAppear(at url: URL) { notifyChange(url) }
  func presentedSubitemDidChange(at url: URL) { notifyChange(url) }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notifyChange(newURL) }
  func presentedItemDidMove(to newURL: URL) {
    lock.withLock { itemURL = newURL }
    changed(.moved(newURL))
  }
  func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
    completionHandler(nil)
    notifyChange()
  }
  func accommodatePresentedSubitemDeletion(
    at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void
  ) {
    completionHandler(nil)
    notifyChange(url)
  }

  deinit { stop() }
}
