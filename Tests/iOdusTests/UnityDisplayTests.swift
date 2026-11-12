import XCTest
@testable import iOdus

/// The saved screen settings of a Unity game in the prefix registry.
final class UnityDisplayTests: XCTestCase {
    /// `reg query` output as Wine prints it, with the values Football Manager 27 saved.
    private func query(width: Int, height: Int) -> String {
        """

        HKEY_CURRENT_USER\\Software\\Sports Interactive\\Football Manager 27
            Screenmanager Fullscreen mode_h3630240806    REG_DWORD    0x1
            Screenmanager Resolution Width_h182942802    REG_DWORD    0x\(String(width, radix: 16))
            Screenmanager Resolution Height_h2627697771    REG_DWORD    0x\(String(height, radix: 16))
            Screenmanager Resolution Use Native_h1405027254    REG_DWORD    0x0
            UnitySelectMonitor_h17969598    REG_DWORD    0x0
            unity.player_session_count_h922449978    REG_BINARY    3200
            Last Career Name    REG_SZ    My career

        """
    }

    func testABrokenSizeIsFound() {
        XCTAssertTrue(UnityGame.hasBrokenSize(query: query(width: 1, height: 1)))
        XCTAssertTrue(UnityGame.hasBrokenSize(query: query(width: 1920, height: 200)))
        XCTAssertFalse(UnityGame.hasBrokenSize(query: query(width: 1920, height: 1080)))
        XCTAssertFalse(UnityGame.hasBrokenSize(query: "\nHKEY_CURRENT_USER\\Software\\A\\B\n"), "Nothing saved yet")
    }

    func testValuesAreReadByTheirExactName() {
        let output = query(width: 3840, height: 2160)
        XCTAssertEqual(UnityGame.dword(UnityGame.widthValue, fromQuery: output), 3840)
        XCTAssertEqual(UnityGame.dword(UnityGame.heightValue, fromQuery: output), 2160)
        XCTAssertEqual(UnityGame.mode(fromQuery: output), 1)
    }

    func testTheResetTakesOnlyTheScreenSettings() {
        XCTAssertEqual(UnityGame.displayValues(fromQuery: query(width: 1, height: 1)), [
            "Screenmanager Fullscreen mode_h3630240806",
            "Screenmanager Resolution Width_h182942802",
            "Screenmanager Resolution Height_h2627697771",
            "Screenmanager Resolution Use Native_h1405027254",
            "UnitySelectMonitor_h17969598",
        ])
    }
}
