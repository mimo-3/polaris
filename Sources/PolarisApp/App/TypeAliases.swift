import PolarisCore
import SwiftUI

/// SwiftUI.State と PolarisCore.State がぶつかるので、アプリ内では State をプロパティラッパーに、
/// 永続状態を AppState と呼び分ける。
typealias State<Value> = SwiftUI.State<Value>
typealias AppState = PolarisCore.State
