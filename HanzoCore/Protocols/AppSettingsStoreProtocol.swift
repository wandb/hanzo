import Foundation

protocol AppSettingsStoreProtocol: AnyObject {
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}
