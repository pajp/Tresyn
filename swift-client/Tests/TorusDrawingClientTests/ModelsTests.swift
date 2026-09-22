import XCTest
@testable import TorusDrawingClient

final class ModelsTests: XCTestCase {
    func testPrimitiveWireKeys() throws {
        let object = DrawingObject(id: "ring", type: .torus, majorRadius: 0.4, minorRadius: 0.1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as! [String: Any]
        XCTAssertEqual(json["major_radius"] as? Double, 0.4)
        XCTAssertEqual(json["minor_radius"] as? Double, 0.1)
        XCTAssertNil(json["position"])
        XCTAssertEqual(json["type"] as? String, "torus")
    }

    func testExtensibleJSONRoundTrip() throws {
        let value = JSONValue.object(["custom": .array([.number(2), .bool(true), .null, .string("x")])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testSceneReply() throws {
        let data = Data(#"{"v":1,"id":"12","ok":true,"result":{"mode":"drawing","object_ids":["a"],"objects":[{"id":"a","type":"sphere"}],"revision":3}}"#.utf8)
        let reply = try JSONDecoder().decode(ServerReply.self, from: data)
        let scene = try reply.decodeResult(SceneState.self)
        XCTAssertEqual(scene.mode, .drawing)
        XCTAssertEqual(scene.objectIDs, ["a"])
        XCTAssertEqual(scene.objects.first?.id, "a")
    }

    func testNotConnected() async {
        let client = TorusClient()
        do { _ = try await client.state(); XCTFail("Expected not-connected error") }
        catch { XCTAssertTrue(String(describing: error).contains("Not connected")) }
        await client.disconnect()
    }
}
