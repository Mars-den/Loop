//
//  AppDefaultAppResourcesTests.swift
//  LoopTests
//

import AppKit
@testable import Loop
import Testing

struct AppDefaultAppResourcesTests {
    @MainActor
    @Test func slowBundleLookupRunsOutsideTheMainThread() async {
        let metadata = await AppDefaultAppResources.metadata(at: URL(fileURLWithPath: "/Example.app")) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .init(bundleID: Thread.isMainThread ? "main" : "worker", name: "Example")
        }
        #expect(metadata?.bundleID == "worker")
    }

    @Test func readsAppMetadataWithoutLaunchingTheApplication() async throws {
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.example.LoopResourceTest",
            "CFBundleDisplayName": "Example App",
            "CFBundleName": "Example",
            "CFBundlePackageType": "APPL"
        ]
        let app = try makeApp(plist: plist)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let metadata = await AppDefaultAppResources.metadata(at: app)
        #expect(metadata?.bundleID == plist["CFBundleIdentifier"])
        #expect(metadata?.name == "Example App")
    }

    @Test(arguments: [true, false])
    func missingDisplayNameUsesBundleNameOrFilename(hasBundleName: Bool) async throws {
        var plist = [
            "CFBundleIdentifier": "com.example.LoopResourceTest.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL"
        ]
        if hasBundleName { plist["CFBundleName"] = "Bundle Name" }
        let app = try makeApp(plist: plist)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let metadata = await AppDefaultAppResources.metadata(at: app)
        #expect(metadata?.name == (hasBundleName ? "Bundle Name" : "Example"))
    }

    @Test func selectedLocationCannotSupplyAnotherAppsIcon() async throws {
        let app = try makeApp(plist: [
            "CFBundleIdentifier": "com.example.SelectedApp.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL"
        ])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let icon = await AppDefaultAppResources.icon(
            bundleID: "com.example.UnavailableApp.\(UUID().uuidString)", appURL: app
        )
        #expect(icon == nil)
    }

    @Test func unavailableAppsReturnFallbackResources() async {
        let id = "com.example.missing.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).app")
        let metadata = await AppDefaultAppResources.metadata(at: url)
        let icon = await AppDefaultAppResources.icon(bundleID: id, appURL: url)
        #expect(metadata == nil)
        #expect(icon == nil)
    }

    private func makeApp(plist: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode/AppDefaultResourceTests-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
