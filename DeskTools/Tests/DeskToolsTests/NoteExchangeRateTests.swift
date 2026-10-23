import Foundation
import NotesCore
import XCTest

final class NoteExchangeRateTests: XCTestCase {
    func testECBDateAndCrossRatesArePreservedWithoutSendingNotes() throws {
        let data = Data(
            #"<gesmes:Envelope xmlns:gesmes="x"><Cube><Cube time="2026-10-12"><Cube currency="USD" rate="1.1181"/><Cube currency="HKD" rate="8.7101"/></Cube></Cube></gesmes:Envelope>"#
                .utf8)
        let rates = try NoteExchangeRates.decodeECB(data)
        XCTAssertEqual(rates.date, "2026-10-12")
        XCTAssertEqual(rates.rates["EUR"], 1)
        XCTAssertEqual(NoteCalculations.evaluate("100 USD in HKD", rates: rates.rates).map(\.output), ["779.01 HKD"])
    }
    func testInvalidRatesAndExternalEntitiesAreRejected() {
        XCTAssertThrowsError(try NoteExchangeRates.decodeECB(Data("<!DOCTYPE x []><Cube/>".utf8)))
        XCTAssertThrowsError(
            try NoteExchangeRates.decodeECB(
                Data(
                    #"<Cube time="not-a-date"><Cube currency="USD" rate="-1"/><Cube currency="HKD" rate="0"/></Cube>"#
                        .utf8)))
        XCTAssertThrowsError(try NoteExchangeRates.decodeECB(Data()))
    }
}
