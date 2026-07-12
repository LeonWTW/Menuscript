import Foundation

/// Views 入面嘅 LocalizedStringKey 由 SwiftUI 自動查表；
/// 由 code 砌出嚟嘅字串（error message、summary 等）經呢度，
/// 跟返 app 內語言設定而唔係系統語言。
enum L10n {
    /// 顯式揀咗語言但搵唔到對應 lproj 時唔可以 fallback 去 Bundle.main：
    /// source 語言（zh-Hant）唔會編出 lproj，而 Bundle.main 會跟系統語言
    /// 揀咗 en，令「英文系統 + app 內揀繁中」錯誤顯示英文。
    /// key 本身就係 zh-Hant 原文，所以直接回傳 key 先係正確 fallback。
    private static func lookup(_ key: String) -> String {
        let lang = AppLanguage.resolve()
        guard let identifier = lang.locale?.identifier else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func string(_ key: String) -> String {
        lookup(key)
    }

    static func string(_ key: String, _ args: CVarArg...) -> String {
        String(format: lookup(key), arguments: args)
    }
}
