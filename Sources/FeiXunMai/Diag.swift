import Foundation
import os.log

/// 诊断日志开关：defaults write com.feixun.mai debugDiag -bool YES 后重启生效。
enum Diag {
    static let on = UserDefaults.standard.bool(forKey: "debugDiag")
}
