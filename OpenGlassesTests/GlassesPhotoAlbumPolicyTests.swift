import Photos
import XCTest
@testable import OpenGlasses

/// The pure half of the consolidated photo-library save path. PhotoKit itself can't run headless,
/// so the decisions that used to be buried in two copies of `fetchGlassesAlbum()` — may we save,
/// which album do we target, was that create failure the duplicate-title race — are tested here
/// and the library calls stay a thin edge in `GlassesPhotoAlbum`.
final class GlassesPhotoAlbumPolicyTests: XCTestCase {

    // MARK: - Authorization

    func testAuthorizedAndLimitedMaySave() {
        XCTAssertTrue(GlassesPhotoAlbumPolicy.canSave(.authorized))
        // `.limited` saved fine before the consolidation and must keep saving: the wearer granted
        // access to a selection, and adding new assets still works.
        XCTAssertTrue(GlassesPhotoAlbumPolicy.canSave(.limited))
    }

    func testUndecidedAndRefusedStatusesMayNotSave() {
        // `.notDetermined` is false on purpose — the caller has to go through the request path,
        // which is the single place the prompt is allowed to come from.
        XCTAssertFalse(GlassesPhotoAlbumPolicy.canSave(.notDetermined))
        XCTAssertFalse(GlassesPhotoAlbumPolicy.canSave(.denied))
        XCTAssertFalse(GlassesPhotoAlbumPolicy.canSave(.restricted))
    }

    // MARK: - Album resolution

    func testValidCachedIdentifierIsUsedWithoutATitleLookup() {
        let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: "album/1",
                                                            cachedAlbumStillExists: true,
                                                            albumFoundByTitle: true)
        XCTAssertEqual(resolution, .useCached("album/1"))
    }

    func testStaleCachedIdentifierFallsBackToTheTitleLookup() {
        // The album was deleted from Photos: the identifier no longer resolves, but a "Glasses"
        // album exists (the wearer made one, or a reinstall lost only the cache).
        let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: "album/gone",
                                                            cachedAlbumStillExists: false,
                                                            albumFoundByTitle: true)
        XCTAssertEqual(resolution, .adoptFoundByTitle)
    }

    func testStaleCachedIdentifierAndNoTitleMatchCreates() {
        let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: "album/gone",
                                                            cachedAlbumStillExists: false,
                                                            albumFoundByTitle: false)
        XCTAssertEqual(resolution, .create)
    }

    func testFirstEverSaveCreates() {
        let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: nil,
                                                            cachedAlbumStillExists: false,
                                                            albumFoundByTitle: false)
        XCTAssertEqual(resolution, .create)
    }

    func testNoCacheButAnExistingAlbumIsAdoptedRatherThanDuplicated() {
        let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: nil,
                                                            cachedAlbumStillExists: false,
                                                            albumFoundByTitle: true)
        XCTAssertEqual(resolution, .adoptFoundByTitle)
    }

    /// The failure mode add-only authorization produces, stated as a test so the reasoning is
    /// checkable rather than just written down: without read access the identifier can't be
    /// validated and the title lookup returns nothing, so every save takes the create path — a
    /// fresh "Glasses" album per capture. This is why the shipped default requests readWrite once.
    func testWithoutReadAccessEverySaveWouldCreateAnotherAlbum() {
        for cached in ["album/1", nil] as [String?] {
            let resolution = GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: cached,
                                                                cachedAlbumStillExists: false,
                                                                albumFoundByTitle: false)
            XCTAssertEqual(resolution, .create,
                           "add-only leaves both lookups blind, so this is the only branch reachable")
        }
    }

    // MARK: - The duplicate-title race

    func testDuplicateAlbumErrorIsRecognised() {
        let error = NSError(domain: PHPhotosErrorDomain,
                            code: GlassesPhotoAlbumPolicy.albumAlreadyExistsCode)
        XCTAssertTrue(GlassesPhotoAlbumPolicy.isAlbumAlreadyExists(error))
    }

    func testOtherPhotoErrorsAreNotTreatedAsTheDuplicateRace() {
        let otherCode = NSError(domain: PHPhotosErrorDomain, code: 3300)
        let otherDomain = NSError(domain: NSCocoaErrorDomain,
                                  code: GlassesPhotoAlbumPolicy.albumAlreadyExistsCode)
        XCTAssertFalse(GlassesPhotoAlbumPolicy.isAlbumAlreadyExists(otherCode))
        XCTAssertFalse(GlassesPhotoAlbumPolicy.isAlbumAlreadyExists(otherDomain))
    }
}
