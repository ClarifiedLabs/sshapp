import XCTest

final class AdaptiveSessionToolbarTests: XCTestCase {
    func testRootUsesOneAvailabilityGatedSystemToolbarWithoutRemountingTabs() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(source.contains("NavigationStack {"))
        XCTAssertFalse(source.contains(".navigationTitle(\"SSH App\")"))
        XCTAssertTrue(source.contains("if #available(iOS 27.1, *)"))
        XCTAssertTrue(source.contains("AdaptiveSessionToolbar("))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .principal)"))
        XCTAssertTrue(source.contains("GeometryReader { proxy in"))
        XCTAssertEqual(source.components(separatedBy: "unifiedTopBar.frame(width: proxy.size.width)").count - 1, 2)
        XCTAssertTrue(source.contains("ZStack {"))
        XCTAssertTrue(source.contains("ForEach(tabs) { tab in"))
        XCTAssertTrue(source.contains(".opacity(isSelected ? 1 : 0)"))
        XCTAssertTrue(source.contains(".allowsHitTesting(isSelected)"))
        XCTAssertTrue(source.contains(".accessibilityHidden(!isSelected)"))
        XCTAssertFalse(
            source.contains("NavigationSplitView") || source.contains(".sidebarAdaptable"),
            "Dynamic terminal sessions must not move into a sidebar-adaptable container"
        )
    }

    func testVerticalAndHorizontalChromeAreMutuallyExclusiveAndAxisAware() throws {
        let source = try readSourceFile("SSHApp/Views/AdaptiveSessionToolbar.swift")

        XCTAssertTrue(source.contains("@available(iOS 27.1, *)"))
        XCTAssertTrue(source.contains("@Environment(\\.toolbarVerticalEdge)"))
        XCTAssertTrue(source.contains("if toolbarVerticalEdge == nil"))
        XCTAssertTrue(source.contains(".axisBehavior(.horizontalOnly)"))
        XCTAssertTrue(source.contains(".axisBehavior(.verticalPreferred)"))
        XCTAssertTrue(source.contains(".visibilityPriority(.high)"))
        XCTAssertTrue(source.contains(".visibilityPriority(.low)"))
        XCTAssertTrue(source.contains("Label(\"Sessions\", systemImage: \"rectangle.on.rectangle\")"))
        XCTAssertTrue(source.contains("Label(newTabTitle, systemImage: \"plus\")"))
        XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")") == false,
                      "The shared settings menu owns the vertical Settings label")
        XCTAssertFalse(source.contains("UIDevice") || source.contains("interfaceOrientation"))
    }

    func testBothChromePresentationsShareSwitcherAndNewTabBehavior() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let adaptiveSource = try readSourceFile("SSHApp/Views/AdaptiveSessionToolbar.swift")
        let actionBody = try extractMethodBody(
            from: mainSource,
            methodName: "private func openTerminalOnSelectedServer"
        )

        XCTAssertEqual(mainSource.components(separatedBy: "ConnectionSwitcherView(").count - 1, 1)
        XCTAssertFalse(barSource.contains("ConnectionSwitcherView("))
        XCTAssertTrue(mainSource.contains("onOpenSwitcher: { connectionSwitcherSource = .horizontal }"))
        XCTAssertTrue(mainSource.contains("onOpenSwitcher: { connectionSwitcherSource = .vertical }"))
        XCTAssertTrue(barSource.contains("onNewTab()"))
        XCTAssertTrue(adaptiveSource.contains("Button(action: onNewTab)"))
        XCTAssertTrue(actionBody.contains("await controller.newWindow()"))
        XCTAssertTrue(actionBody.contains("openSharedChannelInNewTab"))
        XCTAssertTrue(actionBody.contains("addNewTab()"))
    }

    func testDuoFixtureUsesRealMainViewAndNetworkFreeTransport() throws {
        let appSource = try readSourceFile("SSHApp/App/SSHApp.swift")
        let fixtureSource = try readSourceFile("SSHApp/Testing/DuoLayoutUITestHarnessView.swift")

        XCTAssertTrue(appSource.contains("UITestAppState.usesDuoLayoutFixture"))
        XCTAssertTrue(fixtureSource.contains("MainView(initialTabs: [model.tab])"))
        XCTAssertTrue(fixtureSource.contains("ScriptedSSHChannelTransport()"))
        XCTAssertTrue(fixtureSource.contains("markAttachedForLayoutTesting()"))
        XCTAssertFalse(fixtureSource.contains("connectAndAuthenticate"))
    }
}
